module Api
  module V1
    class ProductsController < ApplicationController
      PER_PAGE_DEFAULT = 50
      PER_PAGE_MAX     = 100

      before_action :require_admin!, only: [:update]

      def index
        products = apply_filters(current_tenant.products).order(name: :asc)

        per   = [[params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1].max, PER_PAGE_MAX].min
        paged = products.page(params[:page]).per(per)

        channels_by_product = channels_by_product_id(paged)

        render json: {
          products: paged.map { |p| index_json(p, channels_by_product[p.id] || []) },
          meta:     pagination_meta(paged)
        }
      end

      def show
        product = current_tenant.products.find(params[:id])

        render json: show_json(product)
      end

      def update
        product = current_tenant.products.find(params[:id])

        if product.update(product_params)
          render json: show_json(product)
        else
          render json: { errors: product.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def turnover
        product = current_tenant.products.find(params[:id])
        period  = resolve_period

        items_in_period = OrderItem
          .joins(:order)
          .where(orders: { tenant_id: current_tenant.id, ordered_at: period[:from].beginning_of_day..period[:to].end_of_day })

        direct_sales_qty = items_in_period.where(product_id: product.id).sum(:quantity)
        kit_sales_qty     = compute_kit_sales_qty(items_in_period, product)

        render json: {
          sku:              product.sku,
          name:             product.name,
          period:           { from: period[:from].iso8601, to: period[:to].iso8601 },
          direct_sales_qty: direct_sales_qty,
          kit_sales_qty:    kit_sales_qty,
          total_real_qty:   direct_sales_qty + kit_sales_qty
        }
      end

      private

      def apply_filters(scope)
        scope = scope.where(active: ActiveModel::Type::Boolean.new.cast(params[:active])) if params[:active].present?
        scope = scope.where(is_kit: ActiveModel::Type::Boolean.new.cast(params[:is_kit])) if params[:is_kit].present?

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

      def channels_by_product_id(paged)
        ChannelProductListing
          .where(product_id: paged.map(&:id))
          .pluck(:product_id, :channel)
          .each_with_object(Hash.new { |h, k| h[k] = [] }) { |(product_id, channel), h| h[product_id] << channel }
      end

      def compute_kit_sales_qty(items_in_period, product)
        kit_items = items_in_period
          .joins(:product)
          .where(products: { is_kit: true })
          .includes(product: { kit_components: { component_product: { kit_components: :component_product } } })

        total = 0
        kit_items.find_each do |item|
          next if item.product_id == product.id # já contabilizado em direct_sales_qty

          Products::ExplodeKit.call(item.product, item.quantity).each do |leaf|
            total += leaf[:real_qty] if leaf[:product].id == product.id
          end
        end
        total
      end

      def resolve_period
        to   = params[:to].present?   ? Date.parse(params[:to])   : Date.current
        from = params[:from].present? ? Date.parse(params[:from]) : to - 29.days
        { from: from, to: to }
      rescue ArgumentError
        { from: Date.current - 29.days, to: Date.current }
      end

      def product_params
        params.permit(:sku, :name, :cost_price, :active, :is_kit)
      end

      def index_json(product, channels = nil)
        {
          id:         product.id,
          sku:        product.sku,
          name:       product.name,
          cost_price: product.cost_price,
          active:     product.active,
          is_kit:     product.is_kit,
          channels:   channels || product.channel_product_listings.distinct.pluck(:channel)
        }
      end

      def show_json(product)
        index_json(product).merge(idworks_id: product.idworks_id)
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
