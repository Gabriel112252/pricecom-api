module Integrations
  module Tiktok
    # Maps both Finance API shapes to one order-level representation. TikTok
    # signs fees as negative amounts; Pricecom stores fee columns as positive
    # costs, which is the convention already used by the order endpoint.
    class FinancialTransactionParser
      class InvalidTransactionError < Integrations::ApiError; end

      ORDER_TYPE = "order".freeze
      ADJUSTMENT_TYPE = "adjustment".freeze
      REFUND_TYPE = "refund".freeze
      RESERVE_TYPE = "reserve".freeze
      UNKNOWN_TYPE = "unknown".freeze

      FEE_FIELDS = %w[
        affiliate_ads_commission_amount
        affiliate_commission_amount
        affiliate_partner_commission_amount
        bonus_cashback_service_fee_amount
        credit_card_handling_fee_amount
        fee_per_item_sold_amount
        live_specials_fee_amount
        mall_service_fee_amount
        platform_commission_amount
        referral_fee_amount
        refund_administration_fee_amount
        sfp_service_fee_amount
        transaction_fee_amount
      ].freeze

      def self.call(payload, origin:)
        new(payload, origin: origin).call
      end

      def initialize(payload, origin:)
        @payload = payload
        @origin = origin.to_sym
      end

      def call
        validate_payload!

        case origin
        when :order
          parse_order_payload
        when :statement
          parse_statement_payload
        else
          raise ArgumentError, "origem financeira TikTok inválida: #{origin.inspect}"
        end
      end

      def self.aggregate(transactions, raw_payload: nil)
        rows = Array(transactions)
        raise InvalidTransactionError, "TiktokFinancialParser: nenhuma transação de pedido" if rows.empty?

        seen_transaction_ids = {}
        rows = rows.reject do |row|
          transaction_id = row[:transaction_id].presence
          duplicate = transaction_id.present? && seen_transaction_ids.key?(transaction_id)
          seen_transaction_ids[transaction_id] = true if transaction_id.present?
          duplicate
        end

        fields = %i[
          revenue_amount settlement_amount fee_and_tax_amount shipping_cost_amount
          platform_commission_amount affiliate_commission_amount item_fee_amount
          service_fee_amount other_fees_amount
        ]
        result = fields.index_with { BigDecimal("0") }
        rows.each do |row|
          fields.each { |field| result[field] += BigDecimal(row.fetch(field).to_s) }
        end
        result.merge(
          order_id: rows.map { |row| row[:order_id].to_s }.find(&:present?),
          transaction_type: ORDER_TYPE,
          financial_breakdown: raw_payload || rows.map { |row| row[:financial_breakdown] }
        )
      end

      private

      attr_reader :payload, :origin

      def validate_payload!
        return if payload.is_a?(Hash)

        raise InvalidTransactionError, "TiktokFinancialParser: payload inválido"
      end

      def parse_order_payload
        normalized(
          order_id: required_string(payload["order_id"], "order_id"),
          transaction_type: ORDER_TYPE,
          revenue_amount: required_amount(payload["revenue_amount"], "revenue_amount"),
          settlement_amount: required_amount(payload["settlement_amount"], "settlement_amount"),
          fee_and_tax_amount: fee_amount(payload["fee_and_tax_amount"], "fee_and_tax_amount"),
          shipping_cost_amount: fee_amount(payload["shipping_cost_amount"], "shipping_cost_amount"),
          fee_hashes: Array(payload["sku_transactions"]).map { |transaction| fee_hash_for(transaction, required: false) }
        )
      end

      def parse_statement_payload
        type = statement_type
        order_id = statement_order_id

        # Adjustments and reserves are deliberately represented, but are not
        # eligible for Order financial columns by themselves. They can lack
        # the complete sale components and must never be mistaken for a sale.
        unless type == ORDER_TYPE
          return normalized(
            order_id: order_id,
            transaction_type: type,
            revenue_amount: decimal_or_zero(payload["revenue_amount"]),
            settlement_amount: decimal_or_zero(payload["settlement_amount"] || payload["adjustment_amount"] || payload["reserve_amount"]),
            fee_and_tax_amount: fee_amount(payload["fee_tax_amount"], "fee_tax_amount", required: false),
            shipping_cost_amount: fee_amount(payload["shipping_cost_amount"], "shipping_cost_amount", required: false),
            fee_hashes: [ fee_hash_for(payload, required: false) ],
            processable: false
          )
        end

        normalized(
          order_id: required_string(order_id, "order_id"),
          transaction_type: ORDER_TYPE,
          revenue_amount: required_amount(payload["revenue_amount"], "revenue_amount"),
          settlement_amount: required_amount(payload["settlement_amount"], "settlement_amount"),
          fee_and_tax_amount: fee_amount(payload["fee_tax_amount"] || payload["fee_and_tax_amount"], "fee_tax_amount"),
          shipping_cost_amount: fee_amount(payload["shipping_cost_amount"], "shipping_cost_amount"),
          fee_hashes: [ fee_hash_for(payload) ]
        )
      end

      def normalized(order_id:, transaction_type:, revenue_amount:, settlement_amount:, fee_and_tax_amount:,
        shipping_cost_amount:, fee_hashes:, processable: true)
        platform = sum_fee(fee_hashes, "platform_commission_amount")
        affiliate = sum_fee(fee_hashes, "affiliate_commission_amount")
        item_fee = sum_fee(fee_hashes, "fee_per_item_sold_amount")
        service_fee = sum_fee(fee_hashes, "sfp_service_fee_amount")
        other_fees = fee_hashes.sum(BigDecimal("0")) do |fee_hash|
          fee_hash.keys.reject {
            _1 == "platform_commission_amount" || _1 == "affiliate_commission_amount" ||
              _1 == "fee_per_item_sold_amount" || _1 == "sfp_service_fee_amount"
          }.sum(BigDecimal("0")) { |key| fee_amount(fee_hash[key], key, required: false) }
        end

        {
          transaction_id: payload["id"].presence || payload["transaction_id"].presence,
          order_id: order_id,
          transaction_type: transaction_type,
          processable: processable,
          revenue_amount: revenue_amount,
          settlement_amount: settlement_amount,
          fee_and_tax_amount: fee_and_tax_amount,
          shipping_cost_amount: shipping_cost_amount,
          platform_commission_amount: platform,
          affiliate_commission_amount: affiliate,
          item_fee_amount: item_fee,
          service_fee_amount: service_fee,
          other_fees_amount: other_fees,
          financial_breakdown: payload
        }
      end

      def statement_type
        raw_type = payload["type"].to_s.downcase
        return ADJUSTMENT_TYPE if raw_type.include?("adjust")
        return ADJUSTMENT_TYPE if raw_type.include?("compensation")
        return REFUND_TYPE if raw_type.include?("refund")
        return RESERVE_TYPE if raw_type.include?("reserve")
        return ORDER_TYPE if %w[order order_transaction sale standard].include?(raw_type)
        return ORDER_TYPE if payload["order_id"].present? && raw_type.blank?

        UNKNOWN_TYPE
      end

      def statement_order_id
        payload["order_id"].presence || payload["associated_order_id"].presence || payload["adjustment_order_id"].presence
      end

      def fee_hash_for(transaction, required: true)
        unless transaction.is_a?(Hash)
          raise InvalidTransactionError, "TiktokFinancialParser: sku_transaction inválida" if required

          return {}
        end

        breakdown = transaction["fee_tax_breakdown"]
        if breakdown.nil?
          raise InvalidTransactionError, "TiktokFinancialParser: fee_tax_breakdown ausente" if required

          return {}
        end
        unless breakdown.is_a?(Hash)
          raise InvalidTransactionError, "TiktokFinancialParser: fee_tax_breakdown inválido"
        end

        fee = breakdown["fee"]
        if fee.nil?
          raise InvalidTransactionError, "TiktokFinancialParser: fee_tax_breakdown.fee ausente" if required

          return {}
        end
        unless fee.is_a?(Hash)
          raise InvalidTransactionError, "TiktokFinancialParser: fee_tax_breakdown.fee inválido"
        end

        fee
      end

      def sum_fee(fee_hashes, field)
        Array(fee_hashes).sum(BigDecimal("0")) { |fee_hash| fee_amount(fee_hash[field], field, required: false) }
      end

      def required_string(value, field)
        return value.to_s if value.present?

        raise InvalidTransactionError, "TiktokFinancialParser: campo obrigatório #{field} inválido"
      end

      def required_amount(value, field)
        decimal_amount(value, field, required: true)
      end

      def decimal_or_zero(value)
        decimal_amount(value, "amount", required: false)
      end

      def fee_amount(value, field, required: true)
        decimal_amount(value, field, required: required).abs
      end

      def decimal_amount(value, field, required:)
        if value.nil? || value.to_s.empty?
          return BigDecimal("0") unless required

          raise InvalidTransactionError,
            "TiktokFinancialParser: campo financeiro obrigatório #{field} inválido"
        end

        amount = BigDecimal(value.to_s)
        return amount if amount.finite?

        raise InvalidTransactionError, "TiktokFinancialParser: campo financeiro #{field} inválido"
      rescue ArgumentError, TypeError
        raise InvalidTransactionError, "TiktokFinancialParser: campo financeiro #{field} inválido"
      end
    end
  end
end
