module Integrations
  # Matches idworks invoices (NFs) onto orders that don't have one yet,
  # filling in nf_number/nf_gross_value/nf_discount/nf_freight (used by
  # Audits::DetectOrderConflicts's NF-mismatch checks) plus, when idworks is
  # the configured source (see DataSourceConfig), real_freight_cost and
  # tax_amount — the two fields Order#calculate_margin uses in place of/in
  # addition to the channel-reported freight once they're available.
  #
  # Scoped to sales orders missing an NF by default so a recurring sync
  # only pays the per-order idworks lookup cost once per order, not on
  # every run — pass orders_scope explicitly to resync a specific order or
  # a different window.
  class InvoiceSyncService
    Result = Struct.new(:outcome, :synced_count, :error_message, :metadata, keyword_init: true) do
      def success? = outcome == :success
      def error?   = outcome == :error
    end

    def self.call(integration, orders_scope: nil)
      new(integration, orders_scope: orders_scope).call
    end

    def initialize(integration, orders_scope: nil)
      @integration  = integration
      @tenant       = integration.tenant
      @orders_scope = orders_scope || default_orders_scope
    end

    def call
      log     = start_log
      adapter = IdworksAdapter.new(integration.credentials)
      adapter.authenticate

      synced_count, item_errors = sync_all(adapter)

      integration.update!(status: "connected", last_synced_at: Time.current)
      finish_log(log, status: item_errors.empty? ? "success" : "error", synced_count:, errors: item_errors)

      Result.new(
        outcome: item_errors.empty? ? :success : :error,
        synced_count: synced_count,
        error_message: item_errors.first&.fetch(:message, nil),
        metadata: { errors: item_errors }
      )
    rescue AuthenticationError => e
      integration.update!(status: "error")
      finish_log(log, status: "error", synced_count: 0, errors: [ { message: e.message } ])
      Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: {})
    rescue RateLimitError => e
      finish_log(log, status: "error", synced_count: 0, errors: [ { message: "rate_limited: #{e.message}" } ])
      Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: { retry_after: e.retry_after })
    rescue ApiError => e
      integration.update!(status: "error")
      finish_log(log, status: "error", synced_count: 0, errors: [ { message: e.message } ])
      Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: {})
    end

    private

    attr_reader :integration, :tenant, :orders_scope

    def default_orders_scope
      tenant.orders.sales.where(nf_number: nil).order(ordered_at: :desc)
    end

    def sync_all(adapter)
      synced_count = 0
      item_errors  = []

      orders_scope.find_each do |order|
        invoice = adapter.fetch_invoices(order.order_number.presence || order.external_id)
        next if invoice.blank?

        apply_invoice(order, invoice)
        synced_count += 1
      rescue => e
        item_errors << { order_id: order.id, message: e.message }
      end

      [ synced_count, item_errors ]
    end

    def apply_invoice(order, invoice)
      order.nf_number      = invoice[:nf_number]
      order.nf_gross_value = invoice[:nf_gross_value] if invoice[:nf_gross_value].present?
      order.nf_discount    = invoice[:nf_discount] if invoice[:nf_discount].present?
      order.nf_freight     = invoice[:nf_freight] if invoice[:nf_freight].present?
      order.real_freight_cost = invoice[:real_freight_cost] if freight_from_idworks? && invoice[:real_freight_cost].present?
      order.tax_amount        = invoice[:tax_amount] if tax_from_idworks? && invoice[:tax_amount].present?
      order.save!

      Audits::DetectOrderConflicts.call(order)
    end

    def freight_from_idworks?
      DataSourceConfig.source_for(tenant, "freight") == "idworks"
    end

    def tax_from_idworks?
      DataSourceConfig.source_for(tenant, "tax") == "idworks"
    end

    def start_log
      IntegrationSyncLog.create!(
        tenant: tenant,
        integration: integration,
        direction: "inbound",
        action: "idworks_invoice_sync",
        status: "pending",
        started_at: Time.current,
        metadata: { integration_id: integration.id }
      )
    end

    def finish_log(log, status:, synced_count:, errors:)
      log.update!(
        status: status,
        finished_at: Time.current,
        duration_ms: ((Time.current - log.started_at) * 1000).round,
        error_message: errors.first&.fetch(:message, nil),
        metadata: log.metadata.merge(synced_count: synced_count, error_count: errors.size, errors: errors.first(10))
      )
    end
  end
end
