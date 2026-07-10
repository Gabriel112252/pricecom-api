module Api
  module V1
    class KitComponentsController < ApplicationController
      before_action :require_admin!, only: [:sync]

      def index
        product = current_tenant.products.find(params[:id])

        render json: kit_json(product)
      end

      # Full replace of a kit's composition in one call: the KitBuilder screen
      # sends the whole component list on save rather than per-row requests.
      def sync
        product = current_tenant.products.find(params[:id])

        requested_ids = component_rows.map { |row| row[:component_product_id].to_i }
        valid_ids     = current_tenant.products.where(id: requested_ids).ids.to_set
        invalid_ids   = requested_ids.to_set - valid_ids

        if invalid_ids.any?
          return render json: { errors: ["Produto(s) inválido(s): #{invalid_ids.to_a.join(', ')}"] },
                        status: :unprocessable_entity
        end

        ActiveRecord::Base.transaction do
          product.is_kit = ActiveModel::Type::Boolean.new.cast(params[:is_kit]) if params.key?(:is_kit)
          product.save!

          existing = product.kit_components.index_by(&:component_product_id)

          component_rows.each do |row|
            component_id = row[:component_product_id].to_i
            kit_component = existing.delete(component_id) || product.kit_components.build(component_product_id: component_id)
            kit_component.quantity = row[:quantity]
            kit_component.save!
          end

          existing.each_value(&:destroy!)
        end

        render json: kit_json(product.reload)
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def component_rows
        sync_params[:components] || []
      end

      def sync_params
        params.permit(:is_kit, components: [:component_product_id, :quantity])
      end

      def kit_json(product)
        {
          is_kit:     product.is_kit,
          components: product.kit_components.includes(:component_product).map { |kc| component_json(kc) }
        }
      end

      def component_json(kit_component)
        {
          id:                   kit_component.id,
          component_product_id: kit_component.component_product_id,
          sku:                  kit_component.component_product.sku,
          name:                 kit_component.component_product.name,
          quantity:              kit_component.quantity
        }
      end
    end
  end
end
