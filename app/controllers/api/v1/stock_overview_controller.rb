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

        listings_by_product = ChannelProductListing.where(product_id: paged.map(&:id)).group_by(&:product_id)
        rules_by_product = current_tenant.stock_alert_rules.active.where(product_id: paged.map(&:id)).group_by(&:product_id)

        render json: {
          products: paged.map { |p| product_json(p, listings_by_product[p.id] || [], rules_by_product[p.id] || []) },
          meta: pagination_meta(paged)
        }
      end

      private

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
