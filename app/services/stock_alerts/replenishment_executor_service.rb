module StockAlerts
  # Executes one StockAlert's suggested replenishment for real: resolves
  # the tenant's ChannelCredential/adapter for that channel (same
  # resolution Integrations::ProductSyncService already uses — reused via
  # .adapter_for, not duplicated) and calls #update_stock with the new
  # absolute quantity.
  #
  # Never lets an adapter exception escape: whoever calls this (the
  # automatic path in EvaluationService, or the confirm endpoint) needs to
  # keep going afterwards — an unhandled raise here would abort a job mid
  # loop over unrelated products/alerts.
  class ReplenishmentExecutorService
    Result = Struct.new(:outcome, :error_message, keyword_init: true) do
      def success? = outcome == :success
      def error?   = outcome == :error
    end

    def self.call(stock_alert)
      new(stock_alert).call
    end

    # Shared write path for both automatic replenishment and the manual stock
    # editor. Keeping credential/adapter resolution and channel-specific
    # kwargs here avoids the manual endpoint drifting from the alert engine.
    def self.write_stock(listing, quantity)
      new(listing.tenant).write_stock(listing, quantity)
    end

    def initialize(stock_alert_or_tenant)
      @stock_alert = stock_alert_or_tenant if stock_alert_or_tenant.respond_to?(:suggested_replenishment_qty)
      @tenant = @stock_alert ? @stock_alert.tenant : stock_alert_or_tenant
    end

    def call(stock_alert = @stock_alert)
      @stock_alert = stock_alert

      if EvaluationService::AUTOMATION_INCAPABLE_CHANNELS.include?(stock_alert.channel)
        return fail!("canal sem capacidade de escrita automática")
      end

      listing = find_listing
      return fail!("nenhum ChannelProductListing encontrado para este produto/canal") unless listing

      new_qty = listing.stock_qty.to_d + stock_alert.suggested_replenishment_qty.to_d
      write_stock(listing, new_qty)

      stock_alert.update!(status: "executed", executed_at: Time.current, error_message: nil)
      listing.update!(stock_qty: new_qty)

      Result.new(outcome: :success, error_message: nil)
    rescue Integrations::AuthenticationError, Integrations::RateLimitError,
           Integrations::ApiError, Integrations::UnsupportedOperationError,
           NotImplementedError => e
      fail!(e.message)
    end

    # Resolves the credential/adapter and performs one absolute stock write.
    # The caller decides whether and when to persist the local quantity.
    def write_stock(listing, quantity, credential: nil)
      credential ||= tenant.channel_credentials.find_by(channel: listing.channel)
      unless credential
        raise Integrations::AuthenticationError,
          "nenhuma credencial conectada para o canal #{listing.channel}"
      end

      extra_args = write_args_for(listing.channel, listing)
      raise Integrations::ApiError, extra_args[:error] if extra_args[:error]

      adapter = Integrations::ProductSyncService.adapter_for(credential)
      adapter.update_stock(external_id: listing.external_id, quantity: quantity, **extra_args[:kwargs])
    end

    private

    attr_reader :stock_alert, :tenant

    def find_listing
      ChannelProductListing.find_by(tenant: tenant, product: stock_alert.product, channel: stock_alert.channel)
    end

    # Shopify's #update_stock needs inventory_item_id (not the same value
    # as external_id — see ShopifyAdapter#update_stock), while TikTok needs
    # its parent product_id. Both are resolved from the listing persisted by
    # ProductSyncService. Yampi needs nothing extra because it resolves its
    # own write-context live per call (see YampiAdapter#update_stock).
    def write_args_for(channel, listing)
      case channel
      when "shopify"
        return { error: "listing sem external_inventory_item_id — rode um sync antes de tentar repor" } \
          if listing.external_inventory_item_id.blank?

        { kwargs: { inventory_item_id: listing.external_inventory_item_id } }
      when "tiktok"
        return { error: "listing sem external_product_id — rode um sync antes de tentar repor" } \
          if listing.external_product_id.blank?

        { kwargs: { product_id: listing.external_product_id } }
      else
        { kwargs: {} }
      end
    end

    def fail!(message)
      stock_alert.update!(status: "failed", error_message: message)
      Result.new(outcome: :error, error_message: message)
    end
  end
end
