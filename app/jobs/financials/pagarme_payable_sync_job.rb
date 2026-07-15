module Financials
  class PagarmePayableSyncJob < ApplicationJob
    queue_as :integrations

    def perform(financial_source_id = nil)
      scope = FinancialSource.where(provider: "pagarme", active: true).where.not(status: "inactive")
      scope = scope.where(id: financial_source_id) if financial_source_id.present?

      scope.find_each do |financial_source|
        Financials::PagarmePayableSyncService.call(financial_source)
      end
    end
  end
end
