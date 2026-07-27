module Testimonials
  # Baixa o vídeo original do link do TikTok (Testimonials::TiktokVideoDownloader)
  # e anexa como #media do testimonial — o mesmo player que a Fase 2 já
  # renderiza pra upload manual passa a funcionar pra depoimentos de TikTok
  # também. Enfileirado por TestimonialsController#create_from_tiktok logo
  # após o registro ser criado (o oEmbed síncrono da request já confirmou
  # que o link é válido; o download em si é lento demais pra rodar dentro
  # da request).
  #
  # Só dispara GenerateQuoteTextJob depois que a mídia está anexada — é por
  # isso que o create manual (mídia já anexada na hora da request) dispara
  # GenerateQuoteTextJob direto do controller, sem passar por este job.
  class DownloadTiktokVideoJob < ApplicationJob
    queue_as :integrations

    def perform(testimonial_id)
      testimonial = Testimonial.find_by(id: testimonial_id)
      return unless testimonial
      return if testimonial.media.attached? # já processado (retry, etc.)
      return if testimonial.external_url.blank?

      result = Testimonials::TiktokVideoDownloader.call(testimonial.external_url)
      return unless result[:success]

      testimonial.media.attach(
        io: StringIO.new(result[:bytes]),
        filename: "tiktok-video#{extension_for(result[:content_type])}",
        content_type: result[:content_type]
      )
      testimonial.save! # força a validação de content_type (attach sozinho não roda validations do parent)

      Testimonials::GenerateQuoteTextJob.perform_later(testimonial.id)
    end

    private

    def extension_for(content_type)
      case content_type
      when "video/webm" then ".webm"
      when "video/quicktime" then ".mov"
      else ".mp4"
      end
    end
  end
end
