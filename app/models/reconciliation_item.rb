class ReconciliationItem < ApplicationRecord
  belongs_to :tenant
  belongs_to :integration, optional: true
  belongs_to :product,     optional: true

  validates :sku, presence: true
  validates :period_start, :period_end, presence: true
  validates :idworks_qty, :pricecom_qty, :diff_qty, numericality: true

  scope :for_period, ->(from, to) { where(period_start: from, period_end: to) }

  # diff_pct é indefinido quando idworks_qty é zero (divisão por zero) — um
  # SKU vendido no Pricecom mas nunca faturado no idworks é sinalizado à
  # parte (ver #unmatched_in_idworks?), não por percentual.
  def unmatched_in_idworks?
    idworks_qty.zero? && !pricecom_qty.zero?
  end

  def divergent?(threshold_pct)
    return true if unmatched_in_idworks?
    return false if diff_pct.nil?

    diff_pct.abs > threshold_pct
  end
end
