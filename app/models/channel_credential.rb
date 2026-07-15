class ChannelCredential < ApplicationRecord
  # NOTE: "mercadolivre" (no underscore) deliberately matches
  # Channel::PLATFORMS, not the MercadoLivreAdapter class/file name — the
  # two are independent, and OrderStockDeductionService resolves a
  # ChannelCredential by looking up `order.channel.platform`, so this
  # string has to agree with Channel::PLATFORMS or that lookup silently
  # fails to match.
  CHANNELS = %w[yampi shopify tiktok mercadolivre shopee].freeze
  STATUSES = %w[pending active error].freeze

  # Required credential keys per channel — drives both validation and the
  # frontend's dynamic credential form.
  # webhook_secret (Yampi and Shopify) is generated on each platform's
  # dedicated Webhooks screen — a different value from the API secret_key /
  # access_token used for product sync — and is the only thing
  # WebhookSignatureVerifier can check inbound webhooks against (see that
  # class for details).
  REQUIRED_FIELDS = {
    "yampi"        => %w[alias token secret_key webhook_secret],
    "shopify"      => %w[shop_domain access_token webhook_secret],
    "tiktok"       => %w[app_key app_secret],
    "mercadolivre" => %w[user_id access_token],
    "shopee"       => %w[shop_id partner_id partner_key access_token]
  }.freeze

  belongs_to :tenant
  belongs_to :stock_source_channel, class_name: "ChannelCredential", optional: true

  # fonte_estoque: this channel's ChannelProductListing is the real stock —
  #   ProductSyncService syncs it normally.
  # consumidor_pedido: this channel only sends orders; it never owns stock.
  #   ProductSyncService skips it, and order stock deduction is redirected
  #   to `stock_source_channel` (e.g. Yampi checkout backed by Shopify's
  #   inventory — see Etapa 9b context).
  # ambos: syncs its own catalog/stock AND is a valid deduction source for
  #   other channels that point at it.
  enum :role, { fonte_estoque: 0, consumidor_pedido: 1, ambos: 2 }, default: :ambos

  encrypts :credentials

  validates :channel, presence: true, inclusion: { in: CHANNELS }, uniqueness: { scope: :tenant_id }
  validates :status, inclusion: { in: STATUSES }
  validate :credentials_include_required_fields
  validate :stock_source_required_when_consumidor_pedido
  validate :stock_source_is_valid

  scope :active, -> { where(status: "active") }
  # Channels whose stock is real and syncable — either their own
  # (fonte_estoque) or shared with others too (ambos).
  scope :stock_owning, -> { where(role: [ roles[:fonte_estoque], roles[:ambos] ]) }

  def required_fields
    REQUIRED_FIELDS.fetch(channel, [])
  end

  private

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
