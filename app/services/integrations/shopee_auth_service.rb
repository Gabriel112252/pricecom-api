module Integrations
  # Shopee Open Platform API v2 — assinatura HMAC-SHA256 e ciclo de vida do
  # OAuth de loja (auth_partner → code+shop_id → token/get → refresh).
  #
  # Duas variantes de assinatura (doc: open.shopee.com, "Authorization and
  # Authentication"):
  #   - public: HMAC(partner_key, partner_id + path + timestamp) — usada nos
  #     endpoints de auth (auth_partner, token/get, access_token/get).
  #   - shop:   HMAC(partner_key, partner_id + path + timestamp +
  #     access_token + shop_id) — usada em toda Shop API (orders, products,
  #     payment). Exposta aqui como fonte única; ShopeeAdapter delega.
  #
  # access_token expira em ~4h (expire_in vem na resposta); refresh_token
  # dura 30 dias e é ROTATIVO — cada refresh devolve um refresh_token novo
  # que substitui o anterior, por isso refresh_credential! persiste os dois.
  #
  # partner_id/partner_key ficam por tenant no JSONB de ChannelCredential
  # (mesmo padrão do app_key/app_secret do TikTok). Sandbox: gravar
  # "environment" => "sandbox" no mesmo JSONB troca a base URL — o
  # connect aceita campos extras além dos REQUIRED_FIELDS.
  class ShopeeAuthService
    include AdapterHttp

    PRODUCTION_BASE_URL = "https://partner.shopeemobile.com".freeze
    SANDBOX_BASE_URL    = "https://partner.test-stable.shopeemobile.com".freeze

    AUTH_PARTNER_PATH  = "/api/v2/shop/auth_partner".freeze
    TOKEN_GET_PATH     = "/api/v2/auth/token/get".freeze
    TOKEN_REFRESH_PATH = "/api/v2/auth/access_token/get".freeze

    # Documentado (não retornado pela API): validade do refresh_token.
    REFRESH_TOKEN_TTL = 30.days

    AUTH_ERROR_KEYWORDS = %w[auth token code sign partner invalid_partner].freeze

    # Faz o refresh e persiste os novos tokens no JSONB da credential.
    # Levanta AuthenticationError quando o refresh_token foi rejeitado
    # (expirado/rotacionado fora daqui) — nesse caso a loja precisa
    # reautorizar via OAuth; o caller decide o que fazer com o status.
    def self.refresh_credential!(channel_credential)
      stored = channel_credential.credentials.to_h
      raise AuthenticationError, "ShopeeAuthService: credential sem refresh_token — reautorize a loja" if stored["refresh_token"].blank?

      data = new(stored).refresh_access_token(
        refresh_token: stored["refresh_token"],
        shop_id: stored["shop_id"]
      )

      now = Time.current
      channel_credential.update!(
        status: "active",
        credentials: stored.merge(
          "access_token"             => data["access_token"],
          # Resposta sem refresh_token novo (não deveria acontecer) mantém
          # o atual em vez de apagar e quebrar o próximo ciclo.
          "refresh_token"            => data["refresh_token"].presence || stored["refresh_token"],
          "token_expires_at"         => (now + data["expire_in"].to_i.seconds).iso8601,
          "refresh_token_expires_at" => (now + REFRESH_TOKEN_TTL).iso8601,
          "token_refreshed_at"       => now.iso8601
        ).compact
      )
      channel_credential
    end

    def initialize(credentials)
      @credentials = credentials.to_h.with_indifferent_access
    end

    def base_url
      sandbox? ? SANDBOX_BASE_URL : PRODUCTION_BASE_URL
    end

    # URL para onde o navegador do seller é redirecionado; a Shopee anexa
    # code e shop_id à `redirect` ao voltar (query params já presentes na
    # redirect — o nosso `state` — são preservados).
    def authorize_url(redirect_url:)
      timestamp = Time.now.to_i
      query = {
        partner_id: partner_id,
        timestamp: timestamp,
        sign: public_sign(AUTH_PARTNER_PATH, timestamp),
        redirect: redirect_url
      }
      "#{base_url}#{AUTH_PARTNER_PATH}?#{query.to_query}"
    end

    # code é de uso único e expira em ~10min. Retorna o body com
    # access_token/refresh_token/expire_in no nível raiz.
    def exchange_code(code:, shop_id:)
      post_public(TOKEN_GET_PATH, code: code, shop_id: shop_id.to_i, partner_id: partner_id.to_i)
    end

    def refresh_access_token(refresh_token:, shop_id:)
      post_public(TOKEN_REFRESH_PATH, refresh_token: refresh_token, shop_id: shop_id.to_i, partner_id: partner_id.to_i)
    end

    def public_sign(path, timestamp)
      hmac("#{partner_id}#{path}#{timestamp}")
    end

    def shop_sign(path, timestamp, access_token:, shop_id:)
      hmac("#{partner_id}#{path}#{timestamp}#{access_token}#{shop_id}")
    end

    private

    attr_reader :credentials

    def partner_id
      credentials[:partner_id]
    end

    def sandbox?
      credentials[:environment].to_s == "sandbox"
    end

    def hmac(base_string)
      OpenSSL::HMAC.hexdigest("SHA256", credentials[:partner_key].to_s, base_string)
    end

    # Endpoints de auth usam a assinatura public-level nos query params e o
    # payload em JSON no body.
    def post_public(path, body)
      timestamp = Time.now.to_i
      response = connection(base_url).post(path) do |req|
        req.params = {
          partner_id: partner_id,
          timestamp: timestamp,
          sign: public_sign(path, timestamp)
        }
        req.body = body
      end

      parsed = handle_response(response)
      raise_on_body_error(parsed)
      parsed
    end

    # Como no ShopeeAdapter: HTTP 200 com `error` preenchido no body é o
    # formato normal de falha da Shopee ("" = sucesso).
    def raise_on_body_error(body)
      error_code = body.is_a?(Hash) ? body["error"].to_s : ""
      return if error_code.blank?

      message = body["message"].to_s
      downcased = "#{error_code} #{message}".downcase

      if AUTH_ERROR_KEYWORDS.any? { |k| downcased.include?(k) }
        raise AuthenticationError, "ShopeeAuthService: #{message.presence || 'falha de autenticação'} (#{error_code})"
      else
        raise ApiError, "ShopeeAuthService: #{message.presence || 'erro desconhecido'} (#{error_code})"
      end
    end
  end
end
