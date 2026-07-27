require "base64"

module Testimonials
  # Gera uma sugestão de quote_text a partir de uma imagem (foto do
  # depoimento, ou frame extraído de vídeo — ver FrameExtractor) usando a
  # API de visão da Anthropic. Usa a gem oficial `anthropic` (client lê
  # ANTHROPIC_API_KEY do ENV — ver .env.example), não uma chamada HTTP crua.
  #
  # Só uma sugestão: GenerateQuoteTextJob só usa o resultado se o
  # testimonial ainda não tiver quote_text — nunca sobrescreve o que o
  # curador já digitou.
  class AnthropicVisionClient
    MODEL       = :"claude-opus-5"
    MAX_TOKENS  = 300
    # Tarefa simples e de baixo risco (sugestão de legenda, não decisão
    # crítica) — effort "low" já performa bem pra isso e roda mais barato/
    # rápido num job de background que pode disparar a cada depoimento
    # criado.
    EFFORT = "low"

    PROMPT = <<~PROMPT.freeze
      Você está vendo uma foto (ou frame de vídeo) de um depoimento de
      cliente sobre um produto. Com base só no que aparece na imagem,
      escreva em português, na primeira pessoa como se fosse o próprio
      cliente, uma frase curta de depoimento (1 a 2 frases) adequada pra
      usar em material de marketing. Responda só com a frase, sem aspas e
      sem introdução.
    PROMPT

    def self.call(image_bytes, content_type)
      new.call(image_bytes, content_type)
    end

    def call(image_bytes, content_type)
      response = client.messages.create(
        model: MODEL,
        max_tokens: MAX_TOKENS,
        output_config: { effort: EFFORT },
        messages: [
          {
            role: "user",
            content: [
              {
                type: "image",
                source: { type: "base64", media_type: content_type, data: Base64.strict_encode64(image_bytes) }
              },
              { type: "text", text: PROMPT }
            ]
          }
        ]
      )

      # Classificadores de segurança podem recusar (200 com stop_reason
      # "refusal", não uma exceção) — sem tratamento especial aqui, só
      # tratamos como "não deu pra sugerir nada".
      return nil if response.stop_reason == :refusal

      text_block = response.content.find { |block| block.type == :text }
      text_block&.text&.strip.presence
    rescue Anthropic::Errors::APIError => e
      Rails.logger.warn("Testimonials::AnthropicVisionClient falhou: #{e.message}")
      nil
    end

    private

    def client
      @client ||= Anthropic::Client.new
    end
  end
end
