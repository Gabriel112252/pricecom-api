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
        products = apply_filters(current_tenant.products).order(name: :asc)

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
          scope = scope.joins(:channel_product_listings)
                       .where(channel_product_listings: { channel: params[:channel] })
                       .distinct
        end

        scope
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
