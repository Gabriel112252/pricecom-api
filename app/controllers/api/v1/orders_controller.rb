module Api
  module V1
    class OrdersController < ApplicationController
      PER_PAGE_DEFAULT = 50
      PER_PAGE_MAX     = 100

      def index
        orders = apply_filters(current_tenant.orders.includes(:channel))
          .order(ordered_at: :desc, created_at: :desc)

        per   = [[params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1].max, PER_PAGE_MAX].min
        paged = orders.page(params[:page]).per(per)

        render json: {
          orders: paged.map { |o| index_json(o) },
          meta:   pagination_meta(paged)
        }
      end

      def show
        order = current_tenant.orders
          .includes(:channel, order_items: :product, integration_mappings: :integration)
          .find(params[:id])

        render json: show_json(order)
      end

      private

      def apply_filters(scope)
        scope = scope.where(channel_id:   params[:channel_id])   if params[:channel_id].present?
        scope = scope.where(status:       params[:status])        if params[:status].present?
        scope = scope.where(order_number: params[:order_number])  if params[:order_number].present?
        scope = scope.where(external_id:  params[:external_id])   if params[:external_id].present?

        if params[:customer_name].present?
          scope = scope.where("customer_name ILIKE ?", "%#{params[:customer_name]}%")
        end

        scope = scope.where("ordered_at >= ?", params[:date_from])            if params[:date_from].present?
        scope = scope.where("ordered_at <= ?", params[:date_to])              if params[:date_to].present?
        scope = scope.where("margin_pct >= ?", params[:min_margin_pct].to_f)  if params[:min_margin_pct].present?
        scope = scope.where("margin_pct <= ?", params[:max_margin_pct].to_f)  if params[:max_margin_pct].present?

        scope
      end

      def index_json(order)
        {
          id:               order.id,
          channel_id:       order.channel_id,
          channel_name:     order.channel&.name,
          external_id:      order.external_id,
          order_number:     order.order_number,
          gross_value:      order.gross_value,
          cost_price:       order.cost_price,
          freight:          order.freight,
          discount:         order.discount,
          commission:       order.commission,
          operational_cost: order.operational_cost,
          margin:           order.margin,
          margin_pct:       order.margin_pct,
          status:           order.status,
          customer_name:    order.customer_name,
          items_qty:        order.items_qty,
          ordered_at:       order.ordered_at,
          created_at:       order.created_at
        }
      end

      def show_json(order)
        index_json(order).merge(
          customer_tag:   order.customer_tag,
          state:          order.state,
          payment_method: order.payment_method,
          weight_kg:      order.weight_kg,
          items:          order.order_items.map { |i| item_json(i) },
          mappings:       order.integration_mappings.map { |m| mapping_json(m) }
        )
      end

      def item_json(item)
        {
          id:         item.id,
          product_id: item.product_id,
          sku:        item.sku,
          name:       item.name,
          quantity:   item.quantity,
          unit_price: item.unit_price,
          unit_cost:  item.unit_cost,
          discount:   item.discount
        }
      end

      def mapping_json(mapping)
        {
          integration_id: mapping.integration_id,
          external_id:    mapping.external_id,
          external_type:  mapping.external_type,
          status:         mapping.status,
          last_synced_at: mapping.last_synced_at
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
