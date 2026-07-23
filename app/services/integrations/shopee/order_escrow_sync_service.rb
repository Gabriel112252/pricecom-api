module Integrations
  module Shopee
    # Busca e persiste o get_escrow_detail de UM pedido Shopee já
    # importado, no mesmo modelo do Tiktok::OrderFinancialSyncService:
    # escreve só as colunas financeiras do Order (revenue/settlement/fees +
    # financial_breakdown + commission → calculate_margin) e NÃO re-roda a
    # ingestão — identidade, itens, gross_value e discount pertencem ao
    # pipeline de pedidos.
    #
    # ⚠️ Mapeamento order_income → colunas, A VALIDAR contra um pedido
    # sandbox real (Fase 4 gate):
    # - settlement_amount = escrow_amount (repasse final ao seller)
    # - revenue_amount = original_price − seller_discount −
    #   voucher_from_seller + buyer_paid_shipping_fee: receita "do seller"
    #   pré-taxas — descontos/subsídios da Shopee (shopee_discount,
    #   voucher_from_shopee, coins) NÃO reduzem, mesma régua do fix
    #   platform_discount do TikTok (2026-07-21)
    # - fee_and_tax_amount = Σ |FEE_FIELDS| (a Shopee assina taxas como
    #   negativas; Pricecom guarda custo positivo, convenção TikTok)
    # - shipping_cost_amount = frete líquido que SAI do seller
    #   (final_shipping_fee, convenção: negativo = custo do seller)
    # A identidade revenue − fees − shipping ≈ settlement é gravada em
    # financial_breakdown["_pricecom"]["arithmetic_delta"] pra auditoria —
    # delta alto no sandbox = mapeamento errado, corrigir antes de prod.
    class OrderEscrowSyncService
      class PendingEscrowError < Integrations::ApiError; end

      FEE_FIELDS = %w[
        commission_fee
        service_fee
        seller_transaction_fee
        credit_card_transaction_fee
        escrow_tax
        withholding_tax
        order_ams_commission_fee
        campaign_fee
      ].freeze

      def self.call(order:, channel_credential:, adapter: nil, force: false)
        new(order: order, channel_credential: channel_credential, adapter: adapter, force: force).call
      end

      def initialize(order:, channel_credential:, adapter: nil, force: false)
        @order = order
        @channel_credential = channel_credential
        @adapter = adapter || Integrations::ShopeeAdapter.new(channel_credential.credentials)
        @force = force
      end

      def call
        return order if order.financial_synced_at.present? && !force

        response = adapter.fetch_escrow_detail(order.external_id)
        income = response["order_income"]

        # Escrow ainda não liberado/consolidado pela Shopee: sem
        # order_income não há o que persistir — o pending sync re-tenta.
        if income.blank?
          raise PendingEscrowError,
            "ShopeeOrderEscrowSync: escrow ainda indisponível para order_sn=#{order.external_id}"
        end

        persist!(normalize(income, response))
        order
      end

      private

      attr_reader :order, :channel_credential, :adapter, :force

      def normalize(income, raw_response)
        fee_and_tax = FEE_FIELDS.sum(BigDecimal("0")) { |field| amount(income[field]).abs }
        revenue = amount(income["original_price"]) -
          amount(income["seller_discount"]).abs -
          amount(income["voucher_from_seller"]).abs +
          amount(income["buyer_paid_shipping_fee"])
        settlement = amount(income["escrow_amount"])
        shipping_cost = seller_shipping_cost(income)

        {
          revenue_amount: revenue,
          settlement_amount: settlement,
          fee_and_tax_amount: fee_and_tax,
          shipping_cost_amount: shipping_cost,
          platform_commission_amount: amount(income["commission_fee"]).abs,
          affiliate_commission_amount: amount(income["order_ams_commission_fee"]).abs,
          item_fee_amount: amount(income["seller_transaction_fee"]).abs,
          service_fee_amount: amount(income["service_fee"]).abs,
          original_shipping_fee: optional_amount(income["actual_shipping_fee"]),
          shipping_fee_platform_discount: optional_amount(income["shopee_shipping_rebate"]),
          financial_breakdown: raw_response.merge(
            "_pricecom" => {
              "arithmetic_delta" => (revenue - fee_and_tax - shipping_cost - settlement).to_f.round(2),
              "fee_fields_present" => FEE_FIELDS.select { |f| income[f].present? }
            }
          )
        }
      end

      # final_shipping_fee: negativo quando o frete sai do bolso do seller
      # (convenção documentada; validar no sandbox). Positivo (reembolso ao
      # seller) não vira custo.
      def seller_shipping_cost(income)
        value = amount(income["final_shipping_fee"])
        value.negative? ? value.abs : BigDecimal("0")
      end

      def persist!(normalized)
        attributes = normalized.slice(
          :revenue_amount,
          :settlement_amount,
          :fee_and_tax_amount,
          :shipping_cost_amount,
          :platform_commission_amount,
          :affiliate_commission_amount,
          :item_fee_amount,
          :service_fee_amount
        ).merge(
          financial_breakdown: normalized.fetch(:financial_breakdown),
          financial_synced_at: Time.current,
          # Mesma convenção do TikTok: commission (usada por
          # calculate_margin) = total de taxas da plataforma.
          commission: normalized.fetch(:fee_and_tax_amount)
        )
        # Trio de auditoria de frete (equivalente ao original_shipping_fee
        # do TikTok): só escreve quando o escrow trouxe o campo — nil
        # preserva o "não informado" da auditoria.
        attributes[:original_shipping_fee] = normalized[:original_shipping_fee] if normalized[:original_shipping_fee]
        if normalized[:shipping_fee_platform_discount]
          attributes[:shipping_fee_platform_discount] = normalized[:shipping_fee_platform_discount]
        end

        order.with_lock do
          order.assign_attributes(attributes)
          order.calculate_margin
          order.save!
        end
      end

      def amount(value)
        return BigDecimal("0") if value.nil? || value.to_s.strip.empty?

        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        BigDecimal("0")
      end

      def optional_amount(value)
        return nil if value.nil? || value.to_s.strip.empty?

        amount(value)
      end
    end
  end
end
