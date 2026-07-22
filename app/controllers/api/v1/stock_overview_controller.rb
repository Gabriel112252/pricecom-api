module Api
  module V1
    # Aggregated read-only view for the "Estoque" screen: one row per
    # product with idworks' qty_available (Fase 1) plus every channel's
    # ChannelProductListing#stock_qty and the matching StockAlertRule's
    # min_threshold, if one exists.
    #
    # A dedicated endpoint on purpose, instead of the frontend combining
    # /products + /channel_product_listings + /stock_alert_rules itself:
    # there's no read endpoint for channel_product_listings at all today,
    # and /products is paginated (up to 100/page) — building the per-row
    # channel breakdown here means one query pair regardless of page size,
    # instead of N+1 calls from the frontend.
    class StockOverviewController < ApplicationController
      PER_PAGE_DEFAULT = 50
      PER_PAGE_MAX     = 100

      def index
        products = apply_sort(apply_filters(current_tenant.products))

        per   = [ [ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX ].min
        paged = products.page(params[:page]).per(per)

        listings_by_product = current_tenant.channel_product_listings
          .where(product_id: paged.map(&:id))
          .group_by(&:product_id)
        rules_by_product = current_tenant.stock_alert_rules.active.where(product_id: paged.map(&:id)).group_by(&:product_id)

        render json: {
          products: paged.map { |p| product_json(p, listings_by_product[p.id] || [], rules_by_product[p.id] || []) },
          active_channels: active_channels,
          meta: pagination_meta(paged)
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

      # Same filters as ProductsController#apply_filters, for the same
      # search/channel UX on this screen.
      def apply_filters(scope)
        if params[:q].present?
          term = "%#{params[:q]}%"
          scope = scope.where("sku ILIKE :q OR name ILIKE :q", q: term)
        end

        if params[:channel].present?
          # EXISTS instead of joins(...).distinct: apply_sort below orders by
          # a subquery column that isn't in the SELECT list, which Postgres
          # rejects when combined with "SELECT DISTINCT" (needed here to
          # collapse the one-row-per-listing fanout a plain join produces).
          # EXISTS never fans out in the first place, so no DISTINCT is
          # needed and the two can compose freely.
          scope = scope.where(
            "EXISTS (SELECT 1 FROM channel_product_listings cpl " \
            "WHERE cpl.product_id = products.id AND cpl.tenant_id = products.tenant_id AND cpl.channel = ?)",
            params[:channel]
          )
        end

        scope
      end

      # sort_by is one channel's per-row stock (only sortable columns the
      # frontend exposes today) — anything else falls back to the default
      # name order. stock_qty lives on ChannelProductListing, one join away
      # and not unique per product (a product can have zero or one listing
      # per channel), so this uses a correlated subquery instead of a JOIN:
      # a JOIN would need DISTINCT to avoid duplicating product rows across
      # a page, and Postgres rejects "SELECT DISTINCT" combined with an
      # ORDER BY column that isn't in the SELECT list.
      #
      # sort_by is checked against Channel::PLATFORMS (a fixed whitelist)
      # before being interpolated into the subquery, so it's never
      # attacker-controlled SQL by the time it reaches the string.
      # NULLS LAST in both directions matches the previous frontend-only
      # sort's tie-break: products without a listing for the sorted channel
      # always sink to the bottom, not just for ASC (Postgres' own default
      # would put nulls first on DESC).
      def apply_sort(scope)
        sort_by = params[:sort_by].to_s
        return scope.order(name: :asc) unless Channel::PLATFORMS.include?(sort_by)

        sort_dir = params[:sort_dir].to_s.downcase == "desc" ? "DESC" : "ASC"
        quoted_channel = ActiveRecord::Base.connection.quote(sort_by)

        scope
          .order(Arel.sql(<<~SQL.squish))
            (SELECT stock_qty FROM channel_product_listings cpl
             WHERE cpl.product_id = products.id AND cpl.tenant_id = products.tenant_id AND cpl.channel = #{quoted_channel}
             LIMIT 1) #{sort_dir} NULLS LAST
          SQL
          .order(name: :asc)
      end

      def product_json(product, listings, rules)
        rules_by_channel = rules.index_by(&:channel)

        {
          id: product.id,
          sku: product.sku,
          name: product.name,
          qty_available: product.qty_available,
          channels: listings.map { |listing| channel_json(listing, rules_by_channel[listing.channel]) }
        }
      end

      def channel_json(listing, rule)
        {
          listing_id: listing.id,
          channel: listing.channel,
          stock_qty: listing.stock_qty,
          min_threshold: rule&.min_threshold
        }
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
