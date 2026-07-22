module Api
  module V1
    # Cadastro das regras de alerta/reposição de estoque por produto (Fase 2
    # — uma regra por produto, não mais por produto+canal) — ver
    # StockAlertRule e StockAlerts::EvaluationService, que usa essas regras
    # a cada evento de estoque (venda, sync de canal, sync do idworks) pra
    # decidir se dispara um StockAlert.
    class StockAlertRulesController < ApplicationController
      before_action :require_admin!, only: [ :create, :update, :destroy ]

      def index
        rules = current_tenant.stock_alert_rules
          .includes(:product)
          .order(:product_id)

        render json: rules.map { |r| rule_json(r) }
      end

      def create
        rule = current_tenant.stock_alert_rules.new(rule_params)

        if rule.save
          render json: rule_json(rule), status: :created
        else
          render json: { errors: rule.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        rule = current_tenant.stock_alert_rules.find(params[:id])

        if rule.update(rule_params)
          render json: rule_json(rule)
        else
          render json: { errors: rule.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        rule = current_tenant.stock_alert_rules.find(params[:id])
        rule.destroy!
        head :no_content
      end

      private

      def rule_params
        params.permit(:product_id, :min_threshold, :target_level, :automation_level, :active)
      end

      def rule_json(rule)
        {
          id: rule.id,
          product_id: rule.product_id,
          product_sku: rule.product.sku,
          product_name: rule.product.name,
          min_threshold: rule.min_threshold,
          target_level: rule.target_level,
          automation_level: rule.automation_level,
          active: rule.active
        }
      end
    end
  end
end
