module Integrations
  # Common interface every channel adapter implements, so
  # Integrations::ProductSyncService never needs to know which channel
  # it's talking to.
  class BaseChannelAdapter
    include AdapterHttp

    def initialize(credentials)
      @credentials = credentials.to_h.with_indifferent_access
    end

    # Makes a lightweight authenticated call and raises AuthenticationError
    # if the credentials are rejected. Returns true on success.
    def authenticate
      raise NotImplementedError, "#{self.class} must implement #authenticate"
    end

    # Returns an Array of raw, channel-native hashes — one per purchasable
    # SKU (adapters flatten product/variation nesting internally so every
    # entry here is already 1:1 with #normalize_product).
    def fetch_products
      raise NotImplementedError, "#{self.class} must implement #fetch_products"
    end

    # Looks up current stock for a single external_id. Bulk syncs get stock
    # from #fetch_products already; this exists for a future "refresh one
    # SKU" action and for channels where stock isn't embedded in the
    # product payload.
    def fetch_stock(external_id)
      raise NotImplementedError, "#{self.class} must implement #fetch_stock"
    end

    # Converts one raw hash (as yielded by #fetch_products) into the common
    # shape ProductSyncService upserts from:
    #   { external_id:, external_sku:, name:, price:, stock_qty:, raw: }
    def normalize_product(raw)
      raise NotImplementedError, "#{self.class} must implement #normalize_product"
    end

    private

    attr_reader :credentials
  end
end
