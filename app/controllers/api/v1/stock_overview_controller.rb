module Api
  module V1
    # Two response shapes for the "Estoque" screen, depending on whether a
    # channel filter is active — see #index. A dedicated endpoint on
    # purpose, instead of the frontend combining /products +
    # /channel_product_listings + /stock_alert_rules itself: there's no
    # read endpoint for channel_product_listings at all today, and
    # /products is paginated (up to 100/page) — building the per-row
    # channel breakdown here means one query pair regardless of page size,
    # instead of N+1 calls from the frontend.
    class StockOverviewController < ApplicationController
      PER_PAGE_DEFAULT = 50
      PER_PAGE_MAX     = 100

      # TODO: no business rule for an acceptable stock/origin mismatch
      # exists yet (checked StockAlertRule#target_level — a one-time
      # replenishment target, not a steady-state expectation — and
      # DataSourceConfig, which only picks which system is authoritative
      # per data type, not per-channel expected values). Starting with
      # "any difference counts" until the team defines a real tolerance;
      # every comparison goes through #divergent? so there's one place to
      # change it later (e.g. an absolute or percentage threshold).
      DIVERGENCE_TOLERANCE = 0

      # Without a channel filter ("Visão Central"): one row per product
      # with the origin figure (idworks) and a *summary* of its channels,
      # not the per-channel numbers. Showing every channel as its own
      # column made "0" (real zero stock) indistinguishable from "product
      # doesn't exist on that channel" (blank) at a glance — fixed here at
      # the response shape, not just in the UI, so nothing pulls the raw
      # per-channel numbers back into this view by accident. Grouping by
      # channel parent-product (below) does NOT apply here — the Pricecom
      # Product already IS the grouping unit in this view.
      #
      # With a channel filter: one row per product that HAS a listing on
      # that channel, with that channel's own stock next to the origin
      # figure and their difference — no ambiguity left, since a product
      # without a listing there was already excluded. Rows are further
      # grouped by that channel's own parent-product id (see
      # #channel_grouped_response) when the channel exposes that concept.
      def index
        if params[:channel].present?
          render json: channel_grouped_response
        else
          render json: central_response
        end
      end

      # Single product, every channel it's listed on — origin, channel
      # stock, difference, remote/selling status + eligibility (Fase 2),
      # the product's single StockAlertRule if one exists (Fase 3 — one
      # rule per product, not per channel), and a replenishment history
      # summary derived from StockReplenishmentExecution. Everything the
      # Fase 4 modal needs in one call.
      def show
        product  = current_tenant.products.find(params[:id])
        listings = current_tenant.channel_product_listings.where(product: product)
        rule     = current_tenant.stock_alert_rules.find_by(product: product)

        render json: {
          product: { id: product.id, sku: product.sku, name: product.name }.merge(origin_fields(product)).merge(free_reserve: product.free_reserve),
          rule: rule && rule_json(rule),
          channels: listings.map { |listing| detail_channel_json(listing, product) },
          replenishment_history: replenishment_history_json(product)
        }
      end

      private

      # Union of (credential currently active) and (any real
      # ChannelProductListing exists), not credential status alone.
      #
      # Root cause of a real bug (2026-07-21): TikTok's ChannelCredential
      # spends real time outside "active" — ChannelCredentialsController#
      # connect sets it to "pending" and returns early for tiktok
      # specifically (it only reaches "active" via the separate OAuth
      # callback), and ProductSyncService flips it to "error" on the next
      # auth/API failure with no token-refresh flow anywhere to recover it
      # automatically. None of that deletes the ChannelProductListing rows
      # a past successful sync already created. Filtering on credential
      # status alone made a channel with real, currently-displayed stock
      # data (still shown with its own badges on the older Products.vue
      # screen, which never checks credential status) silently disappear
      # from this screen's filter dropdown. Credential status alone is
      # kept too (not dropped) so a freshly connected channel can still be
      # selected before its first sync has created any listing yet.
      def active_channels
        credential_channels = current_tenant.channel_credentials.where(status: "active", channel: Channel::PLATFORMS).pluck(:channel)
        listing_channels = current_tenant.channel_product_listings.distinct.pluck(:channel)
        (credential_channels | listing_channels).sort
      end

      # Visão Central: plain SQL pagination over Product, unchanged from
      # before grouping existed — the Pricecom Product already is the
      # grouping unit here, so there's nothing to group further. No
      # sort_by support (the frontend never sends one for this view; there
      # is no single sortable per-channel column once every channel is
      # summarized into one badge).
      def central_response
        products = apply_search(current_tenant.products).order(name: :asc)

        per   = [ [ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX ].min
        paged = products.page(params[:page]).per(per)

        listings_by_product = current_tenant.channel_product_listings
          .where(product_id: paged.map(&:id))
          .group_by(&:product_id)

        {
          products: paged.map { |p| central_row_json(p, listings_by_product[p.id] || []) },
          active_channels: active_channels,
          meta: pagination_meta(paged)
        }
      end

      # Visão por canal: starts from that channel's own listings (not
      # Product — the EXISTS-filtered-product approach the old single
      # #apply_filters used doesn't fit once grouping needs the listings
      # themselves), grouped by the channel's own parent-product id
      # (ChannelProductListing#external_product_id — see each adapter's
      # #normalize_product; populated for Shopify/TikTok/Yampi alike).
      #
      # Grouping — and therefore pagination and sorting — happens in Ruby,
      # not SQL: a group's members need to travel together across a page
      # boundary (splitting a product's 3 SKUs across two pages would be a
      # real correctness bug, not just a cosmetic one), and Postgres has no
      # clean way to paginate "groups of rows" while still sorting by an
      # aggregate over each group without a window-function query more
      # complex than this screen's real traffic (a tenant's per-channel
      # catalog, at most a few thousand rows) justifies right now.
      # Kaminari.paginate_array gives the same .page/.per/pagination_meta
      # interface as an AR relation, so nothing downstream needs to know
      # the difference.
      def channel_grouped_response
        channel = params[:channel]
        listings = current_tenant.channel_product_listings.where(channel: channel).includes(:product)

        if params[:q].present?
          term = "%#{params[:q]}%"
          matching_ids = current_tenant.products.where("sku ILIKE :q OR name ILIKE :q", q: term).ids
          listings = listings.where(product_id: matching_ids)
        end

        groups = group_by_channel_parent(listings.to_a)
        sorted = sort_channel_groups(groups)

        per   = [ [ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX ].min
        paged = Kaminari.paginate_array(sorted).page(params[:page]).per(per)

        {
          products: paged.map { |group| channel_group_row_json(group) },
          active_channels: active_channels,
          meta: pagination_meta(paged)
        }
      end

      def apply_search(scope)
        return scope unless params[:q].present?

        term = "%#{params[:q]}%"
        scope.where("sku ILIKE :q OR name ILIKE :q", q: term)
      end

      # Blank external_product_id (channel doesn't expose a parent-product
      # concept, or a listing predates that field being captured) falls
      # back to a synthetic per-listing key — it becomes a "group of 1" and
      # renders as a plain row (see #channel_group_row_json), never forced
      # into an accordion the channel gave no basis for.
      def group_by_channel_parent(listings)
        listings.group_by { |listing| listing.external_product_id.presence || "listing-#{listing.id}" }.values
      end

      # sort_by is the same channel currently filtered (the only sortable
      # column this view has — "Estoque neste canal"); a group sorts by the
      # SUM of its members' stock_qty, which for a group of 1 is just that
      # listing's own value, so no special-casing standalone rows. NULLS
      # LAST in both directions, same tie-break the old SQL version used:
      # a group with no stock data at all always sinks to the bottom.
      def sort_channel_groups(groups)
        sort_by = params[:sort_by].to_s
        return groups.sort_by { |g| g.first.product.name.to_s.downcase } unless Channel::PLATFORMS.include?(sort_by)

        sort_dir = params[:sort_dir].to_s.downcase == "desc" ? -1 : 1

        groups.sort do |a, b|
          a_total = group_stock_total(a)
          b_total = group_stock_total(b)

          next (a_total.nil? ? 1 : 0) <=> (b_total.nil? ? 1 : 0) if a_total.nil? != b_total.nil?
          next a.first.product.name.to_s.downcase <=> b.first.product.name.to_s.downcase if a_total.nil?

          (a_total <=> b_total) * sort_dir
        end
      end

      def group_stock_total(listings)
        values = listings.filter_map(&:stock_qty)
        values.empty? ? nil : values.sum
      end

      # A group of 1 renders exactly like the old flat channel row (same
      # shape #channel_row_json always returned) — grouping is invisible
      # for a channel/product that has no sibling SKUs, per the "não quebra
      # a visão atual" requirement. A real group (2+ listings sharing a
      # parent) gets a distinct shape: totals at the parent level, plus a
      # `children` array of that exact same per-SKU shape for the frontend
      # to render inside the expanded accordion — one row shape reused at
      # both levels instead of two to keep in sync.
      def channel_group_row_json(listings)
        return channel_row_json(listings.first.product, listings.first) if listings.size == 1

        children = listings.map { |listing| channel_row_json(listing.product, listing) }
        channel_total = group_stock_total(listings)
        origin_known = children.select { |c| c[:has_origin] }
        origin_total = origin_known.sum { |c| c[:origin_qty_available].to_d }

        {
          group_key: listings.first.external_product_id,
          name: listings.first.product.name,
          sku_count: listings.size,
          channel_stock_qty: channel_total,
          has_origin: origin_known.any?,
          origin_qty_available: origin_known.any? ? origin_total : nil,
          difference: origin_known.any? && channel_total ? channel_total - origin_total : nil,
          divergent: origin_known.any? && channel_total ? divergent?(channel_total, origin_total) : nil,
          children: children
        }
      end

      def central_row_json(product, listings)
        divergent_count = listings.count { |listing| divergent_for?(product, listing.stock_qty) }

        {
          id: product.id,
          sku: product.sku,
          name: product.name
        }.merge(origin_fields(product)).merge(
          channels_summary: {
            count: listings.size,
            channels: listings.map(&:channel).sort,
            divergent_count: divergent_count
          }
        )
      end

      # listing is nil only if the data changed between the filter query
      # and this fetch (deleted mid-request) — #channel_grouped_response
      # only ever builds listings/groups from that channel's own listings
      # in the first place, so a nil listing here would mean a race, not a
      # normal case.
      def channel_row_json(product, listing)
        channel_qty = listing&.stock_qty
        difference  = channel_qty && has_origin?(product) ? channel_qty - product.qty_available : nil

        {
          id: product.id,
          sku: product.sku,
          name: product.name,
          listing_id: listing&.id,
          channel_stock_qty: channel_qty
        }.merge(origin_fields(product)).merge(
          difference: difference,
          divergent: channel_qty ? divergent_for?(product, channel_qty) : nil
        )
      end

      def detail_channel_json(listing, product)
        difference = has_origin?(product) ? listing.stock_qty - product.qty_available : nil

        {
          listing_id: listing.id,
          channel: listing.channel,
          stock_qty: listing.stock_qty,
          difference: difference,
          divergent: divergent_for?(product, listing.stock_qty),
          channel_priority: listing.channel_priority,
          remote_status: listing.remote_status,
          remote_status_reason: listing.remote_status_reason,
          remote_status_synced_at: listing.remote_status_synced_at,
          status_stale: listing.status_stale?,
          selling_status: listing.selling_status,
          selling_enabled: listing.selling_enabled,
          replenishment_eligible: listing.replenishment_eligible
        }
      end

      def rule_json(rule)
        {
          id: rule.id,
          min_threshold: rule.min_threshold,
          target_level: rule.target_level,
          automation_level: rule.automation_level,
          active: rule.active
        }
      end

      # Aggregated straight from StockReplenishmentExecution — the audit
      # trail Fase 3 built, not re-derived from StockAlert/StockMovement.
      # "Ignorados por inelegibilidade" is exactly the "skipped" status
      # (see StockAlerts::CreateReplenishmentExecution) — a real, visible
      # outcome, not an absence of one.
      def replenishment_history_json(product)
        executions = current_tenant.stock_replenishment_executions
          .where(product: product)
          .order(created_at: :desc)

        succeeded = executions.select { |e| e.status == "succeeded" }

        {
          total_replenished: succeeded.sum { |e| e.confirmed_qty || 0 },
          last_replenishment_at: succeeded.first&.finished_at,
          succeeded_count: succeeded.size,
          failed_count: executions.count { |e| e.status == "failed" },
          skipped_count: executions.count { |e| e.status == "skipped" },
          executions: executions.first(20).map { |e| execution_json(e) }
        }
      end

      def execution_json(execution)
        {
          id: execution.id,
          channel: execution.channel_product_listing.channel,
          status: execution.status,
          trigger_type: execution.trigger_type,
          threshold_qty: execution.threshold_qty,
          target_qty: execution.target_qty,
          previous_qty: execution.previous_qty,
          requested_qty: execution.requested_qty,
          confirmed_qty: execution.confirmed_qty,
          error_message: execution.error_message,
          attempt_count: execution.attempt_count,
          started_at: execution.started_at,
          finished_at: execution.finished_at,
          created_at: execution.created_at
        }
      end

      def origin_fields(product)
        {
          has_origin: has_origin?(product),
          origin_qty_available: has_origin?(product) ? product.qty_available : nil
        }
      end

      # idworks_id and stock_synced_at are only ever set together, by
      # Integrations::Idworks::StockSyncService#apply_to_product, on the
      # first successful ERP match for a product's SKU — a product created
      # purely from a channel sync (ProductSyncService#upsert_listing)
      # never touches either column, so idworks_id.nil? is the definitive
      # "this product has no ERP linkage" check.
      def has_origin?(product)
        product.idworks_id.present?
      end

      def divergent_for?(product, channel_qty)
        has_origin?(product) && divergent?(channel_qty, product.qty_available)
      end

      def divergent?(channel_qty, origin_qty)
        (channel_qty - origin_qty).abs > DIVERGENCE_TOLERANCE
      end

      def pagination_meta(paged)
        {
          current_page: paged.current_page,
          total_pages:  paged.total_pages,
          total_count:  paged.total_count,
          per_page:     paged.limit_value
        }
      end
    end
  end
end
