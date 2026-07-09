module Api
  module V1
    class PricingRulesController < ApplicationController
      def index
        rules = current_tenant.products
          .includes(pricing_rules: :channel)
          .map do |product|
            {
              product: {
                id: product.id,
                sku: product.sku,
                name: product.name,
                cost_price: product.cost_price
              },
              rules: product.pricing_rules.map { |r| rule_json(r) }
            }
          end

        render json: rules
      end

      def show
        rule = PricingRule.joins(:product).where(products: { tenant_id: current_tenant.id }).find(params[:id])
        render json: rule_json(rule)
      end

      def create
        product = current_tenant.products.find(params[:product_id])
        channel = current_tenant.channels.find(params[:channel_id])

        rule = PricingRule.find_or_initialize_by(product: product, channel: channel)
        rule.target_margin_pct = params[:target_margin_pct] || 30
        rule.current_price = params[:current_price]
        rule.save!
        rule.calculate!

        render json: rule_json(rule), status: :created
      end

      def update
        rule = PricingRule.joins(:product).where(products: { tenant_id: current_tenant.id }).find(params[:id])
        rule.update!(
          target_margin_pct: params[:target_margin_pct] || rule.target_margin_pct,
          current_price: params[:current_price] || rule.current_price
        )
        rule.calculate!

        render json: rule_json(rule)
      end

      def calculate
        cost_price     = params[:cost_price].to_f
        op_cost        = params[:operational_cost].to_f
        commission_pct = params[:commission_pct].to_f
        margin_pct     = params[:target_margin_pct].to_f

        if (1.0 - margin_pct / 100.0 - commission_pct / 100.0) <= 0
          return render json: { error: "Margem + comissão não pode ser >= 100%" }, status: :unprocessable_entity
        end

        base            = cost_price + op_cost
        suggested_price = base / (1.0 - margin_pct / 100.0 - commission_pct / 100.0)

        render json: {
          cost_price: cost_price,
          operational_cost: op_cost,
          commission_pct: commission_pct,
          target_margin_pct: margin_pct,
          suggested_price: suggested_price.round(2),
          breakdown: {
            base_cost:        base.round(2),
            commission_value: (suggested_price * commission_pct / 100).round(2),
            margin_value:     (suggested_price * margin_pct / 100).round(2),
            profit:           (suggested_price - base - (suggested_price * commission_pct / 100)).round(2)
          }
        }
      end

      private

      def rule_json(rule)
        {
          id: rule.id,
          product_id: rule.product_id,
          channel_id: rule.channel_id,
          channel_name: rule.channel&.name,
          channel_platform: rule.channel&.platform,
          target_margin_pct: rule.target_margin_pct,
          suggested_price: rule.suggested_price,
          current_price: rule.current_price,
          last_calculated_at: rule.last_calculated_at
        }
      end
    end
  end
end
