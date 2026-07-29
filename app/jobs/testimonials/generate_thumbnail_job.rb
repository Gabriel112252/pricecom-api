module Testimonials
  # Gera #thumbnail (sempre imagem JPEG) a partir de #media quando #media é
  # vídeo, reaproveitando o mesmo Testimonials::FrameExtractor (ffmpeg) já
  # usado por GenerateQuoteTextJob pra extrair um frame pra Anthropic Vision.
  # Quando #media já é imagem, não faz nada — o próprio media_url já serve
  # de thumbnail (ver Api::Public::V1::TestimonialsController#thumbnail_url),
  # sem chamar ffmpeg à toa.
  #
  # Enfileirado de dois pontos, iguais aos de GenerateQuoteTextJob:
  # Api::V1::TestimonialsController#create_manual (mídia já anexada na
  # request) e Testimonials::DownloadTiktokVideoJob (depois que o vídeo
  # baixado do TikTok é anexado).
  class GenerateThumbnailJob < ApplicationJob
    queue_as :integrations

    def perform(testimonial_id)
      testimonial = Testimonial.find_by(id: testimonial_id)
      return unless testimonial
      return if testimonial.thumbnail.attached?
      return unless testimonial.media.attached?
      return unless testimonial.media.content_type.start_with?("video/")

      frame = Testimonials::FrameExtractor.call(testimonial.media)
      return unless frame

      testimonial.thumbnail.attach(
        io: StringIO.new(frame[:bytes]),
        filename: "thumbnail.jpg",
        content_type: frame[:content_type]
      )
    end
  end
end
