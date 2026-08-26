# frozen_string_literal: true

module Integrations
  # Escritas de catálogo que não existiam no adapter legado. Update Price
  # 202309 é um endpoint próprio do TikTok Shop e não exige reauditoria do
  # conteúdo do produto. Mantemos separado para não ampliar silenciosamente
  # a superfície de escrita do sync periódico.
  class TiktokCatalogWriteClient < TiktokAdapter
    PRICE_UPDATE_PATH_PATTERN = %r{\A/product/202309/products/[^/]+/prices/update\z}.freeze

    def update_price(external_id:, product_id:, amount:, currency: "BRL")
      raise ArgumentError, "product_id ausente" if product_id.blank?
      raise ArgumentError, "external_id/SKU id ausente" if external_id.blank?

      decimal = BigDecimal(amount.to_s)
      raise ArgumentError, "Preço precisa ser maior que zero" unless decimal.positive?

      path = "/product/202309/products/#{product_id}/prices/update"
      post(path, {
        skus: [
          {
            id: external_id.to_s,
            price: {
              amount: format("%.2f", decimal),
              currency: currency.to_s.upcase
            }
          }
        ]
      })
    end

    private

    # TiktokAdapter só reconhecia os paths de estoque/activate/deactivate na
    # allowlist de shop_cipher. O endpoint de preço também é shop-scoped.
    def shop_scoped_query_params(path)
      return super unless path.match?(PRICE_UPDATE_PATH_PATTERN)

      shop_cipher = credentials[:shop_cipher].presence
      if shop_cipher.blank?
        raise AuthenticationError,
          "TiktokAdapter: shop_cipher ausente; reautorize a integração TikTok Shop"
      end

      { shop_cipher: shop_cipher }
    end
  end
end
