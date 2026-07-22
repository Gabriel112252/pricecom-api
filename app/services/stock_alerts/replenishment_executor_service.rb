module StockAlerts
  # The low-level "write an absolute stock quantity to a channel" primitive
  # — resolves the tenant's ChannelCredential/adapter for that channel
  # (same resolution Integrations::ProductSyncService already uses, reused
  # via .adapter_for) and calls #update_stock.
  #
  # Two callers, both doing their own bookkeeping around this call:
  # StockAlerts::ExecuteReplenishmentJob (the async replenishment pipeline
  # — see StockReplenishmentExecution) and
  # Api::V1::ChannelProductListingsController#update (the manual stock
  # editor, unrelated to the alert engine — "ajuste manual" stays a
  # correction of that one channel's own sync, not a pool movement).
  # Keeping credential/adapter resolution here avoids either of those two
  # call sites drifting from the other.
  class ReplenishmentExecutorService
    def self.write_stock(listing, quantity)
      new(listing.tenant).write_stock(listing, quantity)
    end

    def initialize(tenant)
      @tenant = tenant
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

    attr_reader :tenant

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
  end
end
