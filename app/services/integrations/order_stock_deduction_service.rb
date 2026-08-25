module Integrations
  # Debits real stock for a sale order against the exact store connection
  # that produced the order. If that connection is consumidor_pedido, the
  # deduction is redirected to its configured stock_source_channel.
  #
  # Legacy orders without channel_credential_id still work while a provider
  # has exactly one connection. Once there are multiple stores, this service
  # refuses to guess rather than debit the wrong inventory.
  class OrderStockDeductionService
    Result = Struct.new(:outcome, :deducted, :error_message, :metadata, keyword_init: true) do
      def success? = outcome == :success
      def skipped? = outcome == :skipped
      def error?   = outcome == :error
    end

    def self.call(order)
      new(order).call
    end

    def initialize(order)
      @order  = order
      @tenant = order.tenant
    end

    def call
      return Result.new(outcome: :skipped, deducted: [], error_message: nil, metadata: { reason: "already processed" }) if order.stock_deducted_at.present?
      return skip("pedido não é uma venda (order_type=#{order.order_type})") unless order.order_type == "sale"

      channel_credential = resolve_order_credential
      unless channel_credential
        connection_count = tenant.channel_credentials.where(channel: order.channel.platform).limit(2).count
        if connection_count > 1
          return error_result("pedido sem channel_credential_id e existem várias lojas para #{order.channel.platform}; baixa não executada")
        end

        return skip("canal '#{order.channel.platform}' não está conectado à sincronização de estoque")
      end

      source = resolve_source(channel_credential)
      return error_result("canal consumidor de pedido sem stock_source_channel configurado") unless source

      deducted = apply_deductions(source, aggregate_real_quantities)

      order.update!(stock_deducted_at: Time.current)
      log_attempt(status: "success", source: source, deducted: deducted)

      Result.new(
        outcome: :success,
        deducted: deducted,
        error_message: nil,
        metadata: {
          source_channel: source.channel,
          source_channel_credential_id: source.id,
          source_connection_name: source.display_name
        }
      )
    rescue => e
      log_attempt(status: "error", source: nil, deducted: [], error_message: e.message)
      Result.new(outcome: :error, deducted: [], error_message: e.message, metadata: {})
    end

    private

    attr_reader :order, :tenant

    def resolve_order_credential
      return order.channel_credential if order.channel_credential

      ChannelCredential.resolve_for(tenant: tenant, channel: order.channel.platform)
    end

    def resolve_source(channel_credential)
      channel_credential.consumidor_pedido? ? channel_credential.stock_source_channel : channel_credential
    end

    def aggregate_real_quantities
      totals = Hash.new(0)

      order.order_items.includes(:product).each do |item|
        next unless item.product

        Products::ExplodeKit.call(item.product, item.quantity).each do |leaf|
          totals[leaf[:product]] += leaf[:real_qty]
        end
      end

      totals
    end

    def apply_deductions(source, quantities)
      quantities.filter_map { |product, qty| apply_deduction_for(product, source, qty) }
    end

    def apply_deduction_for(product, source, qty)
      result = nil

      product.with_lock do
        listing = ChannelProductListing.find_by(
          tenant: tenant,
          channel_credential: source,
          product: product
        )

        # Backward compatibility for a listing created before the migration.
        if listing.nil? && tenant.channel_credentials.where(channel: source.channel).limit(2).count == 1
          listing = ChannelProductListing.find_by(
            tenant: tenant,
            channel: source.channel,
            channel_credential_id: nil,
            product: product
          )
        end
        break unless listing

        previous_stock_qty = listing.stock_qty
        listing.update!(stock_qty: previous_stock_qty.to_f - qty.to_f)
        result = {
          product_id: product.id,
          sku: product.sku,
          deducted_qty: qty.to_f,
          listing_id: listing.id,
          channel_credential_id: source.id,
          connection_name: source.display_name,
          remaining_stock: listing.stock_qty.to_f
        }

        record_channel_movement(listing, previous_stock_qty)
        evaluate_stock_alert(product)
      end

      result
    end

    def record_channel_movement(listing, previous_stock_qty)
      StockMovement.record!(
        tenant: tenant,
        product: listing.product,
        channel: listing.channel,
        kind: "saida",
        previous_qty: previous_stock_qty || 0,
        new_qty: listing.stock_qty,
        source: "order"
      )
    rescue => e
      Rails.logger.error("[StockMovement] order deduction log failed for listing=#{listing.id}: #{e.message}")
    end

    def evaluate_stock_alert(product)
      StockAlerts::EvaluationService.call(product)
    rescue => e
      Rails.logger.error("[StockAlert] event-driven evaluation failed for product=#{product.id}: #{e.message}")
      nil
    end

    def skip(reason)
      order.update!(stock_deducted_at: Time.current)
      Result.new(outcome: :skipped, deducted: [], error_message: nil, metadata: { reason: reason })
    end

    def error_result(message)
      log_attempt(status: "error", source: nil, deducted: [], error_message: message)
      Result.new(outcome: :error, deducted: [], error_message: message, metadata: {})
    end

    def log_attempt(status:, source:, deducted:, error_message: nil)
      IntegrationSyncLog.create!(
        tenant: tenant,
        channel_credential: source || order.channel_credential,
        direction: "inbound",
        action: "stock_deduction",
        status: status,
        external_id: order.external_id,
        external_type: "order",
        started_at: Time.current,
        finished_at: Time.current,
        error_message: error_message,
        metadata: {
          order_id: order.id,
          order_channel: order.channel.platform,
          order_channel_credential_id: order.channel_credential_id,
          order_connection_name: order.channel_credential&.display_name,
          source_channel: source&.channel,
          source_channel_credential_id: source&.id,
          source_connection_name: source&.display_name,
          deducted: deducted
        }
      )
    end
  end
end
