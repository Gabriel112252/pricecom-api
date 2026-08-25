module StockAlerts
  class ReplenishmentExecutorService
    def self.write_stock(listing, quantity)
      new(listing.tenant).write_stock(listing, quantity)
    end

    def initialize(tenant)
      @tenant = tenant
    end

    # Prefer the exact connection persisted on the listing. The channel-only
    # fallback is kept for legacy rows created before multi-store support.
    def write_stock(listing, quantity, credential: nil)
      credential ||= listing.channel_credential
      credential ||= ChannelCredential.resolve_for(tenant: tenant, channel: listing.channel)
      unless credential
        raise Integrations::AuthenticationError,
          "nenhuma credencial única identificada para o canal #{listing.channel}; informe a loja/conexão"
      end

      extra_args = write_args_for(listing.channel, listing)
      raise Integrations::ApiError, extra_args[:error] if extra_args[:error]

      adapter = Integrations::ProductSyncService.adapter_for(credential)
      adapter.update_stock(external_id: listing.external_id, quantity: quantity, **extra_args[:kwargs])
    end

    private

    attr_reader :tenant

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
  end
end
