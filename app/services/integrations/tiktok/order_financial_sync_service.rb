module Integrations
  module Tiktok
    # Fetches and persists the Finance API statement for one already-imported
    # TikTok order. This deliberately does not re-run order ingestion: order
    # identity, items, gross value, discounts and seller/platform discount
    # fields belong to the order/detail pipeline and are left untouched here.
    class OrderFinancialSyncService
      class PendingStatementError < Integrations::ApiError; end

      def self.call(order:, channel_credential:, adapter: nil)
        new(order: order, channel_credential: channel_credential, adapter: adapter).call
      end

      def initialize(order:, channel_credential:, adapter: nil)
        @order = order
        @channel_credential = channel_credential
        @adapter = adapter || Integrations::TiktokAdapter.new(channel_credential.credentials)
      end

      def call
        validate_request!

        response = adapter.fetch_order_statement_transactions(order.external_id)
        validate_response!(response)

        data = response["data"]
        attributes = normalized_attributes(data)

        # The external call intentionally happens before this block. Keep the
        # database lock limited to the financial update itself.
        order.with_lock do
          order.assign_attributes(attributes)
          order.calculate_margin
          order.save!
        end
        order
      end

      private

      attr_reader :order, :channel_credential, :adapter

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

        return if data.is_a?(Hash)

        raise Integrations::ApiError, "TiktokOrderFinancialSync: Finance API retornou data inválido"
      end

      def normalized_attributes(data)
        fee_and_tax_amount = positive_amount(
          data["fee_and_tax_amount"],
          field: "fee_and_tax_amount",
          required: true
        )

        {
          revenue_amount:              decimal_amount(data["revenue_amount"], field: "revenue_amount", required: true),
          settlement_amount:           decimal_amount(data["settlement_amount"], field: "settlement_amount", required: true),
          fee_and_tax_amount:          fee_and_tax_amount,
          shipping_cost_amount:        positive_amount(data["shipping_cost_amount"], field: "shipping_cost_amount", required: true),
          platform_commission_amount:  sum_fee(data, "platform_commission_amount"),
          affiliate_commission_amount: sum_fee(data, "affiliate_commission_amount"),
          item_fee_amount:             sum_fee(data, "fee_per_item_sold_amount"),
          service_fee_amount:          sum_fee(data, "sfp_service_fee_amount"),
          financial_breakdown:          data,
          financial_synced_at:          Time.current,
          commission:                  fee_and_tax_amount
        }
      end

      def sum_fee(data, field)
        transactions = data["sku_transactions"]
        return BigDecimal("0") if transactions.nil? || transactions == []

        unless transactions.is_a?(Array)
          raise Integrations::ApiError,
            "TiktokOrderFinancialSync: sku_transactions inválido"
        end

        transactions.sum(BigDecimal("0")) do |transaction|
          unless transaction.is_a?(Hash)
            raise Integrations::ApiError,
              "TiktokOrderFinancialSync: sku_transaction inválida"
          end

          fee_value = fee_value_for(transaction, field)
          positive_amount(
            fee_value,
            field: "fee_tax_breakdown.fee.#{field}",
            required: false
          )
        end
      end

      def fee_value_for(transaction, field)
        breakdown = transaction["fee_tax_breakdown"]
        return nil if breakdown.nil?
        unless breakdown.is_a?(Hash)
          raise Integrations::ApiError,
            "TiktokOrderFinancialSync: fee_tax_breakdown inválido"
        end

        fee = breakdown["fee"]
        return nil if fee.nil?
        unless fee.is_a?(Hash)
          raise Integrations::ApiError,
            "TiktokOrderFinancialSync: fee_tax_breakdown.fee inválido"
        end

        fee[field]
      end

      def positive_amount(value, field:, required:)
        decimal_amount(value, field: field, required: required).abs
      end

      def decimal_amount(value, field:, required:)
        if value.nil? || value.to_s.empty?
          return BigDecimal("0") unless required

          raise Integrations::ApiError,
            "TiktokOrderFinancialSync: campo financeiro obrigatório #{field} inválido"
        end

        amount = BigDecimal(value.to_s)
        return amount if amount.finite?

        raise Integrations::ApiError,
          "TiktokOrderFinancialSync: campo financeiro #{field} inválido"
      rescue ArgumentError, TypeError
        raise Integrations::ApiError,
          "TiktokOrderFinancialSync: campo financeiro #{field} inválido"
      end
    end
  end
end
