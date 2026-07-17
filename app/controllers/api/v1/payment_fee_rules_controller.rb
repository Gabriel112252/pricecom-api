module Api
  module V1
    # Cadastro manual das taxas negociadas com a adquirente (Pagar.me) — não
    # há API que exponha isso, só a dashboard deles pra consulta humana. Ver
    # PaymentFeeRule e Financials::PagarmePayableSyncService#expected_fee_amount_for,
    # que usa essas regras pra comparar contra a taxa realmente cobrada.
    class PaymentFeeRulesController < ApplicationController
      before_action :require_admin!, only: [ :create, :update, :destroy ]

      def index
        rules = current_tenant.payment_fee_rules
          .order(:payment_method, :card_brand, :installments_from)

        render json: rules.map { |r| rule_json(r) }
      end

      def create
        rule = current_tenant.payment_fee_rules.new(rule_params)

        if rule.save
          render json: rule_json(rule), status: :created
        else
          render json: { errors: rule.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        rule = current_tenant.payment_fee_rules.find(params[:id])

        if rule.update(rule_params)
          render json: rule_json(rule)
        else
          render json: { errors: rule.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        rule = current_tenant.payment_fee_rules.find(params[:id])
        rule.destroy!
        head :no_content
      end

      private

      def rule_params
        params.permit(
          :payment_method, :card_brand, :installments_from, :installments_to,
          :rate_type, :rate_value, :fixed_fee_boleto, :fixed_fee_gateway,
          :fixed_fee_antifraud, :withdrawal_fee, :anticipation_rate,
          :valid_from, :valid_until
        )
      end

      def rule_json(rule)
        {
          id: rule.id,
          payment_method: rule.payment_method,
          card_brand: rule.card_brand,
          installments_from: rule.installments_from,
          installments_to: rule.installments_to,
          rate_type: rule.rate_type,
          rate_value: rule.rate_value,
          fixed_fee_boleto: rule.fixed_fee_boleto,
          fixed_fee_gateway: rule.fixed_fee_gateway,
          fixed_fee_antifraud: rule.fixed_fee_antifraud,
          withdrawal_fee: rule.withdrawal_fee,
          anticipation_rate: rule.anticipation_rate,
          valid_from: rule.valid_from,
          valid_until: rule.valid_until
        }
      end
    end
  end
end
