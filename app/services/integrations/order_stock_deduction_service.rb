module Integrations
  # Debits real stock for a sale order against the correct
  # ChannelProductListing — "correct" meaning the order's channel's
  # `stock_source_channel` when that channel's role is consumidor_pedido
  # (e.g. a Yampi checkout order debits Shopify's inventory instead of
  # creating a disconnected, phantom Yampi stock record), or the channel's
  # own listing otherwise (fonte_estoque / ambos).
  #
  # Reuses Products::ExplodeKit (Etapa 5) so a kit sale debits its real
  # components, never the kit "product" itself.
  #
  # Idempotent via Order#stock_deducted_at: an order can be re-upserted many
  # times (webhook retries, status-change events) but must only ever be
  # debited once.
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

      channel_credential = tenant.channel_credentials.find_by(channel: order.channel.platform)
      return skip("canal '#{order.channel.platform}' não está conectado à sincronização de estoque") unless channel_credential

      source = resolve_source(channel_credential)
      return skip("canal consumidor de pedido sem stock_source_channel configurado") unless source

      deducted = apply_deductions(source, aggregate_real_quantities)

      order.update!(stock_deducted_at: Time.current)
      log_attempt(status: "success", source: source, deducted: deducted)

      Result.new(outcome: :success, deducted: deducted, error_message: nil, metadata: { source_channel: source.channel })
    rescue => e
      log_attempt(status: "error", source: nil, deducted: [], error_message: e.message)
      Result.new(outcome: :error, deducted: [], error_message: e.message, metadata: {})
    end

    private

    attr_reader :order, :tenant

    def resolve_source(channel_credential)
      channel_credential.consumidor_pedido? ? channel_credential.stock_source_channel : channel_credential
    end

    # Sums real (post-kit-explosion) quantities per base Product across
    # every line of the order. Gifts are included on purpose — a free item
    # is still a physical unit leaving the shelf.
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

    # Deliberately does NOT clamp at zero: a negative resulting stock_qty
    # is a real, honest signal that this SKU oversold on the source
    # channel and needs attention, not something to silently hide.
    def apply_deductions(source, quantities)
      quantities.filter_map { |product, qty| apply_deduction_for(product, source, qty) }
    end

    # Locks the Product row (not the listing) per product, in its own short
    # transaction — deliberately NOT one transaction wrapping the whole
    # order's multiple products: two concurrent orders sharing products A
    # and B, each locking them in a different order, would deadlock. Locking
    # one product at a time, released before moving to the next, can't
    # produce that cycle.
    #
    # The lock's job is to serialize "decrement this product's channel
    # stock, then decide whether an alert/replenishment fires" against any
    # other order hitting the same product at the same time — without it,
    # two near-simultaneous orders could both read Product#free_reserve
    # before either write lands, and both independently decide to replenish
    # (or neither would, each thinking the other still has headroom).
    #
    # StockAlerts::EvaluationService never makes an HTTP call itself — on a
    # threshold crossing it only creates a "pending" StockReplenishmentExecution
    # (see StockAlerts::CreateReplenishmentExecution) and enqueues
    # StockAlerts::ExecuteReplenishmentJob, which does the actual remote
    # write asynchronously, outside this lock entirely. That separation is
    # what makes it safe to call EvaluationService from inside the lock at
    # all — a Postgres row lock held for the duration of a live network
    # round-trip to a channel API would serialize unrelated orders behind
    # a slow/unresponsive channel, and this lock never needs to.
    def apply_deduction_for(product, source, qty)
      result = nil

      product.with_lock do
        listing = ChannelProductListing.find_by(tenant: tenant, channel: source.channel, product: product)
        break unless listing

        previous_stock_qty = listing.stock_qty
        listing.update!(stock_qty: previous_stock_qty.to_f - qty.to_f)
        result = { product_id: product.id, sku: product.sku, deducted_qty: qty.to_f, listing_id: listing.id, remaining_stock: listing.stock_qty.to_f }

        # Deliberately rescued narrowly and kept inside the lock, same
        # reasoning as ProductSyncService#evaluate_stock_alert: a bug in
        # logging or alert evaluation must never roll back the deduction
        # above (`with_lock` wraps this whole block in one transaction — an
        # unrescued raise here would silently undo a real, correct stock
        # write because of an unrelated alerting bug).
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

    def log_attempt(status:, source:, deducted:, error_message: nil)
      IntegrationSyncLog.create!(
        tenant: tenant,
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
          source_channel: source&.channel,
          deducted: deducted
        }
      )
    end
  end
end
