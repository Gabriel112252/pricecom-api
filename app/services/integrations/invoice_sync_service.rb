module Integrations
  # STUB — intentionally NOT called from anywhere. See
  # IdworksController#sync, which only runs
  # Integrations::Idworks::ProductCostSyncService and
  # Integrations::Idworks::OrderSyncService.
  #
  # This class originally assumed idworks' invoice endpoint carried
  # nf_gross_value/nf_discount/nf_freight/tax_amount/real_freight_cost.
  # Confirmed via swagger.idworks.com.br (2026-07-10) that this is wrong:
  #   - GET /invoice returns only NF metadata (IDNfCompany, NfeNumber,
  #     NfeSerie, IDOrder, StatusInvoice, customer data) — no monetary
  #     values, freight, or tax at all.
  #   - GET /invoice/danfe returns a PDF/XML file (the DANFE document
  #     itself), not structured data — unusable for reconciliation.
  #
  # real_freight_cost moved to Integrations::Idworks::OrderSyncService
  # (GET /orders, ValueShipping field), which actually has the data.
  # tax_amount has no idworks source at all right now (see
  # Idworks::ProductCostSyncService's class comment on the tax gate) and
  # stays nil/0 until a real tax data source is integrated.
  #
  # Left in place rather than deleted in case NF-number/status tracking
  # (IDOrder -> NfeNumber/StatusInvoice, no monetary fields) becomes useful
  # later — nothing currently reads or writes that data path, so building
  # it now would be speculative.
  class InvoiceSyncService
    def self.call(*)
      raise NotImplementedError,
        "Integrations::InvoiceSyncService is a documented stub (see class comment) — " \
        "idworks' invoice endpoints have no financial data. Use " \
        "Integrations::Idworks::OrderSyncService for real_freight_cost."
    end
  end
end
