module Integrations
  # Common interface every ERP adapter implements (idworks today) — mirrors
  # BaseChannelAdapter's shape but for the kind of data an ERP is the source
  # of truth for (real product cost, real shipping cost) rather than a
  # sales channel's catalog/orders. Shares HTTP/error handling with
  # BaseChannelAdapter via AdapterHttp instead of duplicating it.
  class BaseErpAdapter
    include AdapterHttp

    def initialize(credentials)
      @credentials = credentials.to_h.with_indifferent_access
    end

    # Makes a lightweight authenticated call and raises AuthenticationError
    # if the credentials are rejected. Returns true on success.
    def authenticate
      raise NotImplementedError, "#{self.class} must implement #authenticate"
    end

    # Returns an Array of { sku:, cost_last_purchase:, cost_average: } — the
    # ERP's real cost figures per SKU, matched onto Product by sku (see
    # Integrations::Idworks::ProductCostSyncService, which decides field
    # priority). No tax rate here — see that service's class comment for
    # why tax isn't synced from idworks.
    def fetch_products
      raise NotImplementedError, "#{self.class} must implement #fetch_products"
    end

    # Returns an Array of { order_ref:, idworks_order_id:, value_shipping:,
    # value_product:, value_order:, value_paid: } for orders in [from, to] —
    # the ERP's real shipping cost per order (see
    # Integrations::Idworks::OrderSyncService).
    def fetch_orders(from:, to:)
      raise NotImplementedError, "#{self.class} must implement #fetch_orders"
    end

    private

    attr_reader :credentials
  end
end
