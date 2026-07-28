module Integrations
  module Tiktok
    # Fetches and persists the Finance API statement for one already-imported
    # TikTok order. This deliberately does not re-run order ingestion: order
    # identity, items, gross value, discounts and seller/platform discount
    # fields belong to the order/detail pipeline and are left untouched here.
    class OrderFinancialSyncService
      class PendingStatementError < Integrations::ApiError; end

      def self.call(order:, channel_credential:, adapter: nil, force: false)
        new(order: order, channel_credential: channel_credential, adapter: adapter, force: force).call
      end

      def self.persist!(order:, normalized:)
        attributes = normalized.slice(
          :revenue_amount,
          :settlement_amount,
          :fee_and_tax_amount,
          :shipping_cost_amount,
          :platform_commission_amount,
          :affiliate_commission_amount,
          :affiliate_ads_commission_amount,
          :affiliate_partner_commission_amount,
          :item_fee_amount,
          :service_fee_amount
        ).merge(
          financial_breakdown: normalized.fetch(:financial_breakdown),
          financial_synced_at: Time.current,
          commission: normalized.fetch(:fee_and_tax_amount)
        )

        order.with_lock do
          order.assign_attributes(attributes)
          order.calculate_margin
          order.save!
        end
        order
      end

      def initialize(order:, channel_credential:, adapter: nil, force: false)
        @order = order
        @channel_credential = channel_credential
        @adapter = adapter || Integrations::TiktokAdapter.new(channel_credential.credentials)
        @force = force == true
      end

      def call
        validate_request!
        return order if order.financial_synced_at.present? && !force

        response = adapter.fetch_order_statement_transactions(order.external_id)
        validate_response!(response)

        normalized = FinancialTransactionParser.call(response["data"], origin: :order)
        self.class.persist!(order: order, normalized: normalized)
      rescue FinancialTransactionParser::InvalidTransactionError => e
        raise Integrations::ApiError, "TiktokOrderFinancialSync: #{e.message}"
      end

      private

      attr_reader :order, :channel_credential, :adapter, :force

      def validate_request!
        if order.external_id.to_s.strip.blank?
          raise ArgumentError, "TiktokOrderFinancialSync: order.external_id é obrigatório"
        end

        platform = order.channel&.platform.to_s
        unless platform.casecmp?("tiktok")
          raise ArgumentError, "TiktokOrderFinancialSync: o pedido precisa pertencer ao canal TikTok"
        end

        if order.tenant_id != channel_credential.tenant_id
          raise ArgumentError, "TiktokOrderFinancialSync: pedido e credencial pertencem a tenants diferentes"
        end

        unless channel_credential.channel == "tiktok"
          raise ArgumentError, "TiktokOrderFinancialSync: a credencial precisa ser do canal TikTok"
        end

        return if channel_credential.status == "active"

        raise ArgumentError, "TiktokOrderFinancialSync: a credencial TikTok precisa estar ativa"
      end

      def validate_response!(response)
        unless response.is_a?(Hash) && response["code"] == 0
          code = response.is_a?(Hash) ? response["code"] : nil
          message = response.is_a?(Hash) ? response["message"] : nil
          raise Integrations::ApiError,
            "TiktokOrderFinancialSync: Finance API retornou code=#{code.inspect} message=#{message.inspect}"
        end

        data = response["data"]
        if data.nil? || data == {}
          raise PendingStatementError,
            "TiktokOrderFinancialSync: Finance API ainda não disponibilizou o demonstrativo"
        end

        unless data.is_a?(Hash)
          raise Integrations::ApiError, "TiktokOrderFinancialSync: Finance API retornou data inválido"
        end

        # A Finance API pode responder code=0 com um Hash "válido" (order_id
        # presente) mas com o statement ainda não fechado — nesse caso ela
        # devolve sku_transactions: [] e total_count: 0, com todos os campos
        # financeiros como "0" explícito. Sem essa checagem, esse zero-
        # placeholder era persistido como sucesso definitivo (financial_synced_at
        # preenchido com revenue_amount/settlement_amount = 0 pra sempre).
        if data["sku_transactions"].blank? || (data.key?("total_count") && data["total_count"].to_i.zero?)
          raise PendingStatementError,
            "TiktokOrderFinancialSync: Finance API ainda não fechou o demonstrativo (sku_transactions vazio)"
        end
      end
    end
  end
end
