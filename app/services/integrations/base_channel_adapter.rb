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
    # external_inventory_item_id: is an optional extra key some channels
    # add (Shopify today — see ShopifyAdapter#normalize_product) for a
    # write-path identifier that isn't the same as external_id. Channels
    # that don't have an equivalent simply omit the key; ProductSyncService
    # copies whatever is present without branching on channel.
    def normalize_product(raw)
      raise NotImplementedError, "#{self.class} must implement #normalize_product"
    end

    # Writes an absolute stock quantity to the channel for one SKU/variant.
    # Not every channel can implement this safely yet — see each adapter's
    # #update_stock for why (UnsupportedOperationError vs. a real call).
    # Must never swallow a failure: the caller (a future stock-alert/
    # reallocation mechanism) needs a raised exception to know the write
    # didn't happen, not a silently-ignored no-op.
    def update_stock(external_id:, quantity:)
      raise NotImplementedError, "#{self.class} must implement #update_stock"
    end

    private

    attr_reader :credentials
  end
end
