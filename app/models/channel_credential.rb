class ChannelCredential < ApplicationRecord
  # NOTE: "mercadolivre" (no underscore) deliberately matches
  # Channel::PLATFORMS, not the MercadoLivreAdapter class/file name.
  # "lucrofrete" is not a sales channel; it shares this encrypted credential
  # store but does not create a Channel row.
  CHANNELS = %w[yampi shopify tiktok mercadolivre shopee lucrofrete].freeze
  STATUSES = %w[pending active error].freeze

  REQUIRED_FIELDS = {
    "yampi"        => %w[alias token secret_key webhook_secret],
    "shopify"      => %w[shop_domain access_token webhook_secret],
    "tiktok"       => %w[app_key app_secret],
    "mercadolivre" => %w[user_id access_token],
    "shopee"       => %w[partner_id partner_key],
    "lucrofrete"   => %w[email password]
  }.freeze

  belongs_to :tenant
  belongs_to :stock_source_channel, class_name: "ChannelCredential", optional: true

  has_many :channel_product_listings, dependent: :nullify
  has_many :product_registration_publications, dependent: :nullify
  has_many :orders, dependent: :nullify
  has_many :integration_events, dependent: :nullify

  # fonte_estoque: this connection owns real stock.
  # consumidor_pedido: it only sends orders and deducts another connection.
  # ambos: it owns stock and may also be used as another connection's source.
  enum :role, { fonte_estoque: 0, consumidor_pedido: 1, ambos: 2 }, default: :ambos

  encrypts :credentials

  before_validation :normalize_name

  validates :channel, presence: true, inclusion: { in: CHANNELS }
  validates :name, presence: true, uniqueness: { scope: [ :tenant_id, :channel ] }
  validates :status, inclusion: { in: STATUSES }
  validate :credentials_include_required_fields
  validate :stock_source_required_when_consumidor_pedido
  validate :stock_source_is_valid

  scope :active, -> { where(status: "active") }
  scope :stock_owning, -> { where(role: [ roles[:fonte_estoque], roles[:ambos] ]) }
  scope :for_channel, ->(channel) { where(channel: channel) }

  def self.default_name_for(channel)
    return "Lucrofrete" if channel.to_s == "lucrofrete"

    Channel::DEFAULT_NAMES.fetch(channel.to_s, channel.to_s.humanize)
  end

  # Compatibility helper for code paths that historically only knew a
  # provider string. With one connection it behaves exactly as before; with
  # multiple connections the caller must disambiguate by id or name.
  def self.resolve_for(tenant:, channel:, id: nil, name: nil)
    scope = tenant.channel_credentials.where(channel: channel)
    return scope.find_by(id: id) if id.present?
    return scope.find_by(name: name.to_s.strip) if name.present?

    records = scope.order(:id).limit(2).to_a
    records.one? ? records.first : nil
  end

  def display_name
    name.presence || self.class.default_name_for(channel)
  end

  def required_fields
    REQUIRED_FIELDS.fetch(channel, [])
  end

  private

  def normalize_name
    self.name = name.to_s.strip.presence || self.class.default_name_for(channel)
  end

  def credentials_include_required_fields
    missing = required_fields.reject { |field| credential_value(field).present? }
    return if missing.empty?

    errors.add(:credentials, "faltando campo(s): #{missing.join(', ')}")
  end

  def credential_value(field)
    values = credentials.to_h
    values[field].presence || values[field.to_sym].presence
  end

  def stock_source_required_when_consumidor_pedido
    return unless consumidor_pedido?
    return if stock_source_channel_id.present?

    errors.add(:stock_source_channel, "é obrigatório quando o papel é 'consumidor de pedido'")
  end

  def stock_source_is_valid
    return unless stock_source_channel_id.present?

    if stock_source_channel_id == id
      errors.add(:stock_source_channel, "não pode ser o próprio canal")
    elsif stock_source_channel.nil? || stock_source_channel.tenant_id != tenant_id
      errors.add(:stock_source_channel, "canal inválido")
    elsif stock_source_channel.consumidor_pedido?
      errors.add(:stock_source_channel, "precisa ser um canal 'fonte de estoque' ou 'ambos'")
    end
  end
end
