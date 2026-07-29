class Testimonial < ApplicationRecord
  SOURCE_TYPES = %w[manual tiktok shopee].freeze
  STATUSES     = %w[draft approved published rejected].freeze

  # Upload manual aceita foto OU vídeo (curador escolhe) — antes desta
  # allowlist, #media não tinha nenhuma validação de content_type, então
  # qualquer arquivo (inclusive não-mídia) era aceito silenciosamente.
  ALLOWED_MEDIA_CONTENT_TYPES = %w[
    image/jpeg image/png image/webp image/gif
    video/mp4 video/quicktime video/webm
  ].freeze

  # Fluxo de curadoria: draft é sempre o ponto de entrada (manual, ou
  # criado a partir de um import TikTok/Shopee); daí só anda pra frente
  # (approved -> published) ou sai pro beco sem saída (rejected) — nunca
  # volta pra draft nem pula etapa. Ver #status_transition_must_be_allowed.
  TRANSITIONS = {
    "draft"     => %w[approved rejected],
    "approved"  => %w[published rejected],
    "published" => [],
    "rejected"  => []
  }.freeze

  belongs_to :tenant
  belongs_to :product, optional: true

  # source_type: manual (curador sobe texto/mídia direto) ou cache de um
  # depoimento importado de TikTok/Shopee (ver tiktok_metadata/external_url).
  has_one_attached :media

  validates :customer_name, presence: true
  validates :source_type, presence: true, inclusion: { in: SOURCE_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :rating, inclusion: { in: 1..5 }, allow_nil: true

  validate :product_belongs_to_same_tenant, if: -> { product_id.present? }
  validate :status_transition_must_be_allowed, if: -> { persisted? && status_changed? }
  validate :media_content_type_must_be_allowed, if: -> { media.attached? }

  scope :by_status, ->(status) { where(status: status) }
  scope :by_source_type, ->(source_type) { where(source_type: source_type) }
  scope :for_product, ->(product_id) { where(product_id: product_id) }

  def draft?
    status == "draft"
  end

  def approved?
    status == "approved"
  end

  def published?
    status == "published"
  end

  def rejected?
    status == "rejected"
  end

  def approve!
    update!(status: "approved", approved_at: Time.current)
  end

  def publish!
    update!(status: "published", published_at: Time.current)
  end

  def reject!
    update!(status: "rejected")
  end

  private

  def product_belongs_to_same_tenant
    errors.add(:product, "inválido") if product.nil? || product.tenant_id != tenant_id
  end

  def status_transition_must_be_allowed
    allowed = TRANSITIONS.fetch(status_was, [])
    return if allowed.include?(status)

    errors.add(:status, "transição inválida de #{status_was} para #{status}")
  end

  def media_content_type_must_be_allowed
    return if ALLOWED_MEDIA_CONTENT_TYPES.include?(media.content_type)

    errors.add(:media, "formato não suportado (use JPEG/PNG/WEBP/GIF ou MP4/MOV/WEBM)")
  end
end
