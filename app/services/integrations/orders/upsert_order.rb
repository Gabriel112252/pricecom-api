module Integrations
  module Orders
    class UpsertOrder
      Result = Struct.new(:ok, :order, :error_message, keyword_init: true) do
        def success? = ok
      end

      def self.call(tenant:, normalized:, integration: nil, provider: nil)
        new(tenant: tenant, normalized: normalized, integration: integration, provider: provider).call
      end

      def initialize(tenant:, normalized:, integration: nil, provider: nil)
        @tenant      = tenant
        @normalized  = normalized
        @integration = integration
        @provider    = provider
      end

      def call
        channel = resolve_channel
        return Result.new(ok: false, order: nil, error_message: "Canal não encontrado para provider '#{@provider}'") unless channel

        ActiveRecord::Base.transaction do
          order = upsert_order(channel)
          upsert_items(order)
          recalculate_costs(order, channel)
          upsert_order_mapping(order)
          mark_cart_converted(order)
          run_conflict_detection(order)
          run_stock_deduction(order)
          Result.new(ok: true, order: order, error_message: nil)
        end
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, order: nil, error_message: e.message)
      rescue => e
        Result.new(ok: false, order: nil, error_message: e.message)
      end

      private

      def resolve_channel
        return @integration.channel if @integration&.channel
        return @tenant.channels.find_by(platform: @provider) if @provider
        nil
      end

      def upsert_order(channel)
        order = @tenant.orders.find_or_initialize_by(channel: channel, external_id: @normalized[:external_id])
        attrs = {
          channel:          channel,
          order_number:     @normalized[:order_number],
          status:           @normalized[:status],
          payment_method:   @normalized[:payment_method],
          customer_name:    @normalized[:customer_name],
          customer_tag:     @normalized[:customer_tag],
          state:            @normalized[:state],
          order_type:       @normalized[:order_type] || "sale",
          refund_amount:    @normalized[:refund_amount].to_f,
          nf_number:        @normalized[:nf_number],
          nf_gross_value:   @normalized[:nf_gross_value].to_f,
          nf_discount:      @normalized[:nf_discount].to_f,
          nf_freight:       @normalized[:nf_freight].to_f,
          gross_value:      @normalized[:gross_value].to_f,
          freight:          @normalized[:freight].to_f,
          discount:         @normalized[:discount].to_f,
          items_qty:        @normalized[:items].sum { |i| (i[:quantity] || 1).to_i },
          ordered_at:       @normalized[:ordered_at] || Time.current,
          # Placeholders — recalculated after items are upserted
          cost_price:       0,
          commission:       0,
          operational_cost: 0
        }
        attrs[:coupon_code] = @normalized[:coupon_code].presence if order_has_coupons?
        attrs[:coupon_discount] = @normalized[:coupon_discount].to_f if order_has_coupons?
        attrs[:cart_token] = @normalized[:cart_token].presence if order_has_cart_token?
        attrs[:shipping_service] = @normalized[:shipping_service].presence if order_has_shipping_service?
        if order_has_shipping_fee_audit?
          attrs[:original_shipping_fee]          = @normalized[:original_shipping_fee]
          attrs[:shipping_fee_platform_discount] = @normalized[:shipping_fee_platform_discount]
          attrs[:shipping_fee_seller_discount]   = @normalized[:shipping_fee_seller_discount]
        end

        order.assign_attributes(attrs)
        order.save!
        order
      end

      def upsert_items(order)
        order.order_items.destroy_all

        @normalized[:items].each do |item_data|
          product = find_or_upsert_product(item_data)
          upsert_product_mapping(product, item_data) if product && @integration

          order.order_items.create!(
            product:       product,
            sku:           item_data[:sku],
            name:          item_data[:name],
            quantity:      item_data[:quantity],
            unit_price:    item_data[:unit_price].to_f,
            unit_cost:     unit_cost_for_item(item_data, product),
            discount:      item_data[:discount].to_f,
            is_gift:       item_data[:is_gift] || false,
            nf_unit_price: item_data[:nf_unit_price].to_f
          )
        end
      end

      def find_or_upsert_product(item_data)
        sku = item_data[:sku].presence
        return nil if sku.blank?

        product = @tenant.products.find_or_initialize_by(sku: sku)

        if product.new_record?
          product.assign_attributes(
            name:       item_data[:name].presence || sku,
            cost_price: (idworks_cost_source? || item_data[:is_gift]) ? 0 : item_data[:unit_cost].to_f,
            active:     true
          )
        else
          product.name = item_data[:name] if item_data[:name].present? && product.name.blank?
          # Never overwrite idworks/manual source-of-truth cost from a marketplace order item.
          unless idworks_cost_source? || item_data[:is_gift]
            product.cost_price = item_data[:unit_cost].to_f if item_data[:unit_cost].to_f > 0
          end
        end

        product.save!
        product
      end

      def unit_cost_for_item(item_data, product)
        return 0 if item_data[:is_gift]
        return item_data[:unit_cost].to_f unless idworks_cost_source?

        cost = product&.cost_price
        cost.present? && cost.to_f > 0 ? cost : nil
      end

      def upsert_product_mapping(product, item_data)
        external_id = item_data[:external_product_id].presence || item_data[:sku]

        mapping = IntegrationMapping.find_or_initialize_by(
          tenant:        @tenant,
          integration:   @integration,
          external_type: "product",
          external_id:   external_id
        )
        mapping.assign_attributes(
          mappable:       product,
          external_code:  item_data[:sku],
          status:         "active",
          last_synced_at: Time.current,
          metadata:       mapping.metadata.merge(
            "provider"  => @provider,
            "item_name" => item_data[:name]
          )
        )
        mapping.save!
      end

      def recalculate_costs(order, _channel)
        ::Orders::RecalculateFinancials.call(order, run_audit: false)
      end

      def idworks_cost_source?
        @idworks_cost_source ||= DataSourceConfig.source_for(@tenant, "cost") == "idworks"
      end

      def order_has_coupons?
        @order_has_coupons ||= Order.column_names.include?("coupon_code")
      end

      def order_has_cart_token?
        @order_has_cart_token ||= Order.column_names.include?("cart_token")
      end

      def order_has_shipping_service?
        @order_has_shipping_service ||= Order.column_names.include?("shipping_service")
      end

      def order_has_shipping_fee_audit?
        @order_has_shipping_fee_audit ||= Order.column_names.include?("original_shipping_fee")
      end

      def upsert_order_mapping(order)
        return unless @integration

        mapping = IntegrationMapping.find_or_initialize_by(
          tenant:        @tenant,
          integration:   @integration,
          external_type: "order",
          external_id:   @normalized[:external_id]
        )
        mapping.assign_attributes(
          mappable:       order,
          external_code:  @normalized[:order_number],
          status:         "active",
          last_synced_at: Time.current,
          metadata:       mapping.metadata.merge(
            "provider"     => @provider,
            "order_number" => @normalized[:order_number]
          )
        )
        mapping.save!
      end

      # Cart → order conversion: the normalizer surfaces the originating
      # checkout cart's token (the order payload's root-level `cart_token`,
      # verified in production) as :cart_token. The match key on the Cart
      # side is `token`, NOT external_id. Best-effort by design — a missing
      # cart (not yet polled, other channel) must never fail order ingestion.
      def mark_cart_converted(order)
        cart_token = @normalized[:cart_token].to_s
        return if cart_token.blank?

        cart = @tenant.carts.find_by(channel: order.channel, token: cart_token)
        return unless cart

        unless cart.status == "converted" && cart.converted_order_id == order.id
          cart.mark_converted!(order)
        end

        # LucroFrete real_freight_cost is no longer derived from raw cart
        # quote logs here. The scheduled OrdersSyncService consumes
        # /api/reports/orders, where LucroFrete already matched the order.
      rescue => e
        Rails.logger.error("[Integrations::Orders::UpsertOrder] mark_cart_converted failed for order_id=#{order.id} cart_token=#{cart_token}: #{e.message}")
      end

      def run_conflict_detection(order)
        Audits::DetectOrderConflicts.call(order)
      rescue => e
        Rails.logger.error("[Integrations::Orders::UpsertOrder] Audits::DetectOrderConflicts failed for order_id=#{order.id}: #{e.message}")
      end

      def run_stock_deduction(order)
        Integrations::OrderStockDeductionService.call(order)
      rescue => e
        Rails.logger.error("[Integrations::Orders::UpsertOrder] OrderStockDeductionService failed for order_id=#{order.id}: #{e.message}")
      end
    end
  end
end
