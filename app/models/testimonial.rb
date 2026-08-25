class Testimonial < ApplicationRecord
  SOURCE_TYPES = %w[manual tiktok shopee mercadolivre amazon].freeze
  STATUSES     = %w[draft approved published rejected].freeze

  # Upload manual aceita foto OU vídeo (curador escolhe) — antes desta
  # allowlist, #media não tinha nenhuma validação de content_type, então
  # qualquer arquivo (inclusive não-mídia) era aceito silenciosamente.
  ALLOWED_MEDIA_CONTENT_TYPES = %w[
    image/jpeg image/png image/webp image/gif
    video/mp4 video/quicktime video/webm
  ].freeze

  # Fluxo de curadoria: draft é sempre o ponto de entrada (manual, ou
  # criado a partir de um import TikTok/Shopee/Mercado Livre/Amazon); daí só anda
  # pra frente (approved -> published) ou sai pro beco sem saída (rejected)
  # — nunca volta pra draft nem pula etapa. Ver
  # #status_transition_must_be_allowed.
  TRANSITIONS = {
    "draft"     => %w[approved rejected],
    "approved"  => %w[published rejected],
    "published" => [],
    "rejected"  => []
  }.freeze

  belongs_to :tenant

  # DEPRECATED: um testimonial pode estar vinculado a vários produtos agora
  # (ver #products/#testimonial_products abaixo — ex: "Protetor Solar FPS
  # 70" vendido como 3 produtos distintos por variação de quantidade). Esta
  # coluna/associação não é mais lida nem escrita pelo app; mantida (não
  # removida) só pra não exigir uma migration de rollback com perda de dado
  # caso precise reverter. TestimonialProduct já foi backfillado a partir
  # dela (ver db/migrate/20260729150000_create_testimonial_products.rb).
  belongs_to :product, optional: true

  has_many :testimonial_products, dependent: :destroy
  has_many :products, through: :testimonial_products

  # source_type identifica a origem real do conteúdo: manual, TikTok,
  # Shopee, Mercado Livre ou Amazon. external_url preserva o link público original
  # quando a origem fornece um, sem precisar criar coluna nova por canal.
  has_one_attached :media

  # Sempre uma imagem (JPEG), nunca vídeo — gerado por
  # Testimonials::GenerateThumbnailJob a partir de um frame de #media
  # quando #media é vídeo (ver Testimonials::FrameExtractor, já usado pra
  # gerar quote_text). Fica vazio quando #media é imagem: nesse caso o
  # próprio media_url já serve de thumbnail, ver
  # Api::Public::V1::TestimonialsController#thumbnail_url.
  has_one_attached :thumbnail

  validates :customer_name, presence: true
  validates :source_type, presence: true, inclusion: { in: SOURCE_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :rating, inclusion: { in: 1..5 }, allow_nil: true

  validate :status_transition_must_be_allowed, if: -> { persisted? && status_changed? }
  validate :media_content_type_must_be_allowed, if: -> { media.attached? }

  scope :by_status, ->(status) { where(status: status) }
  scope :by_source_type, ->(source_type) { where(source_type: source_type) }
  scope :for_product, ->(product_id) { joins(:testimonial_products).where(testimonial_products: { product_id: product_id }) }

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
