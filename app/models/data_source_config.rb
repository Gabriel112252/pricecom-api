class DataSourceConfig < ApplicationRecord
  belongs_to :tenant

  DATA_TYPES = %w[cost freight tax payment_reconciliation].freeze
  SOURCES    = %w[idworks pagarme].freeze
  AVAILABLE_SOURCES_BY_DATA_TYPE = {
    "cost" => %w[idworks],
    "freight" => %w[idworks],
    "tax" => [],
    "payment_reconciliation" => %w[pagarme]
  }.freeze

  # Which source a data_type defaults to the first time its provider is
  # connected (see IdworksController#connect / PagarmeController#connect and
  # the data_source_configs:seed_defaults rake task for tenants connected
  # before this config existed). A tenant can repoint any of these later —
  # this is only the initial value, never enforced afterwards.
  #
  # "tax" is deliberately absent from idworks' defaults: confirmed via
  # swagger.idworks.com.br (2026-07-10) that idworks has no usable tax-rate
  # field anywhere (only fiscal classification codes), so it's never a
  # valid default source for "tax" — see
  # Integrations::Idworks::ProductCostSyncService's class comment.
  DEFAULTS_BY_SOURCE = {
    "idworks" => %w[cost freight],
    "pagarme" => %w[payment_reconciliation]
  }.freeze

  validates :data_type, presence: true, inclusion: { in: DATA_TYPES }, uniqueness: { scope: :tenant_id }
  validates :source,    presence: true, inclusion: { in: SOURCES }

  scope :enabled, -> { where(enabled: true) }

  # Idempotent: only fills in a data_type that has no config yet. Never
  # overwrites a source a tenant has already (deliberately) chosen.
  def self.ensure_default!(tenant, data_type, source)
    tenant.data_source_configs.find_or_create_by!(data_type: data_type) do |c|
      c.source  = source
      c.enabled = true
    end
  end

  def self.ensure_defaults_for_source!(tenant, source)
    DEFAULTS_BY_SOURCE.fetch(source, []).map { |data_type| ensure_default!(tenant, data_type, source) }
  end

  def self.source_for(tenant, data_type)
    tenant.data_source_configs.enabled.find_by(data_type: data_type)&.source
  end

  def self.available_sources_for(data_type)
    AVAILABLE_SOURCES_BY_DATA_TYPE.fetch(data_type.to_s, SOURCES)
  end
end
