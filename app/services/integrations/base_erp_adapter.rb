module Integrations
  # Common interface every ERP adapter implements (idworks today) — mirrors
  # BaseChannelAdapter's shape but for the kind of data an ERP is the source
  # of truth for (real product cost/tax, invoices) rather than a sales
  # channel's catalog/orders. Shares HTTP/error handling with
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

    # Returns an Array of { sku:, cost:, tax_rate: } — the ERP's real cost
    # and tax rate per SKU, matched onto Product by sku (see
    # Integrations::Idworks::ProductCostSyncService).
    def fetch_products_with_cost
      raise NotImplementedError, "#{self.class} must implement #fetch_products_with_cost"
    end

    # Looks up the invoice (NF) issued for a single order, keyed by
    # whatever reference the ERP indexes orders under (order_number today).
    # Returns nil when no invoice has been matched/issued yet, or:
    #   { nf_number:, nf_gross_value:, nf_discount:, nf_freight:,
    #     tax_amount:, real_freight_cost: }
    def fetch_invoices(order_ref)
      raise NotImplementedError, "#{self.class} must implement #fetch_invoices"
    end

    private

    attr_reader :credentials
  end
end
