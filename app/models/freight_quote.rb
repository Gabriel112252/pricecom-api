class FreightQuote < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel

  validates :external_id, presence: true, uniqueness: { scope: :tenant_id }

  # Opções cotadas como array de hashes já normalizados — ver
  # Integrations::Lucrofrete::QuotesPollingService#normalize_quotes.
  def quote_options
    quotes.is_a?(Array) ? quotes.select { |q| q.is_a?(Hash) } : []
  end
end
