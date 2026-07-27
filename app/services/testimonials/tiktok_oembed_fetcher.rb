require "faraday"

module Testimonials
  # Busca metadata pública de um vídeo do TikTok via oEmbed
  # (developers.tiktok.com/doc/embed-videos) — endpoint público, sem
  # autenticação/app credentials, diferente dos outros clients TikTok em
  # Integrations:: que falam com a Partner API assinada (ver
  # TiktokRequestSigning). Por isso não reusa Integrations::AdapterHttp: seu
  # #handle_response distingue 401/403/429/etc., e aqui qualquer falha (link
  # inválido, vídeo removido/privado, timeout) deve virar o mesmo erro
  # genérico — o chamador (TestimonialsController) não tem como diferenciar
  # os casos, então não faz sentido o fetcher fingir que diferencia.
  class TiktokOembedFetcher
    ENDPOINT       = "https://www.tiktok.com/oembed".freeze
    TIMEOUT_SECONDS = 5
    GENERIC_ERROR  = "link inválido ou vídeo indisponível".freeze

    def self.call(url)
      new.call(url)
    end

    def call(url)
      response = connection.get(ENDPOINT, url: url)
      return failure unless response.status == 200 && response.body.is_a?(Hash)

      success(response.body)
    rescue Faraday::Error
      failure
    end

    private

    def connection
      Faraday.new do |f|
        f.response :json, content_type: /json/i
        f.options.timeout      = TIMEOUT_SECONDS
        f.options.open_timeout = TIMEOUT_SECONDS
        f.adapter Faraday.default_adapter
      end
    end

    def success(body)
      {
        success: true,
        data: {
          "title" => body["title"],
          "author_name" => body["author_name"],
          "thumbnail_url" => body["thumbnail_url"],
          "html" => body["html"]
        }
      }
    end

    def failure
      { success: false, error: GENERIC_ERROR }
    end
  end
end
