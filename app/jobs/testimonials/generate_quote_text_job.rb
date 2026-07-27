module Testimonials
  # Sugere um quote_text a partir da mídia anexada do testimonial (foto, ou
  # frame extraído de vídeo — ver FrameExtractor) via
  # Testimonials::AnthropicVisionClient. Funciona igual pra source_type
  # manual (dispara direto do controller, mídia já anexada na request) e
  # tiktok (dispara de DownloadTiktokVideoJob, depois que o vídeo baixado é
  # anexado).
  #
  # Só preenche quote_text se estiver vazio — nunca sobrescreve um texto que
  # o curador já digitou (na criação manual ou numa edição posterior).
  class GenerateQuoteTextJob < ApplicationJob
    queue_as :integrations

    def perform(testimonial_id)
      testimonial = Testimonial.find_by(id: testimonial_id)
      return unless testimonial
      return if testimonial.quote_text.present?
      return unless testimonial.media.attached?

      frame = Testimonials::FrameExtractor.call(testimonial.media)
      return unless frame

      quote = Testimonials::AnthropicVisionClient.call(frame[:bytes], frame[:content_type])
      return if quote.blank?

      testimonial.update!(quote_text: quote)
    end
  end
end
