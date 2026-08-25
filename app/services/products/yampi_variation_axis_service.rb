# frozen_string_literal: true

module Products
  # Garante que o produto-base da Yampi possui exatamente um eixo de
  # variação antes de criar o novo SKU. Quando o produto ainda é simples,
  # converte-o para o eixo "Quantidade" e transforma o SKU-base em
  # "1 unidade". A conversão preserva preço/estoque/dimensões do SKU-base e
  # possui compensação explícita se a criação do novo SKU falhar.
  class YampiVariationAxisService
    Result = Struct.new(
      :variation_id,
      :variation_name,
      :target_value_id,
      :target_value_name,
      :target_value_created,
      :converted_from_simple,
      :base_value_id,
      :base_value_name,
      keyword_init: true
    )

    QUANTITY_VARIATION_NAME = "Quantidade"

    def initialize(client:, registration:, parent_sku:, product_id:)
      @client = client
      @registration = registration
      @parent_sku = parent_sku
      @product_id = product_id
    end

    def call
      axes = sku_variation_axes(parent_sku)
      product = nil

      if axes.empty?
        product = client.fetch_product(product_id)
        axes = product_variation_axes(product)
      end

      if axes.size > 1
        raise Products::YampiProductPublicationService::PublicationError.new(
          "multiple_variation_axes_not_supported",
          "O produto-base possui #{axes.size} eixos de variação. O cadastro guiado não vai adivinhar uma combinação."
        )
      end

      return build_existing_axis_result(axes.first) if axes.one?

      product ||= client.fetch_product(product_id)
      unless truthy_simple?(product["simple"])
        raise Products::YampiProductPublicationService::PublicationError.new(
          "variation_axis_missing",
          "A Yampi informou que o produto não é simples, mas não retornou nenhum eixo de variação. Nada foi alterado."
        )
      end

      convert_simple_product!
    end

    # Chamado pelo publisher se a conversão simple -> variação foi concluída,
    # mas o POST do novo SKU falhou. Restaura o SKU-base e o produto para o
    # formato simples. Os cadastros globais "Quantidade"/valores podem ficar
    # na loja, pois removê-los seria arriscado se outra operação os adotou.
    def rollback_conversion!(result)
      return unless result&.converted_from_simple

      begin
        client.update_sku(parent_sku.fetch("id"), base_sku_update_payload([]))
      rescue => e
        Rails.logger.error(
          "[YampiVariationAxisService] rollback base sku=#{parent_sku['id']} failed: #{e.message}"
        )
      end

      begin
        client.update_product(product_id, { simple: true, variations_ids: [] })
      rescue => e
        Rails.logger.error(
          "[YampiVariationAxisService] rollback product=#{product_id} failed: #{e.message}"
        )
      end
    end

    private

    attr_reader :client, :registration, :parent_sku, :product_id

    def build_existing_axis_result(axis)
      variation_id = axis_id(axis)
      if variation_id.blank?
        raise Products::YampiProductPublicationService::PublicationError.new(
          "variation_id_missing",
          "A Yampi não retornou o ID do eixo de variação do produto-base."
        )
      end

      variation_name = axis_name(axis).presence || QUANTITY_VARIATION_NAME
      target_name = target_value_name
      target_value, created = client.find_or_create_variation_value(
        variation_id: variation_id,
        name: target_name
      )

      Result.new(
        variation_id: variation_id,
        variation_name: variation_name,
        target_value_id: target_value["id"],
        target_value_name: target_value["name"].presence || target_name,
        target_value_created: created,
        converted_from_simple: false
      )
    end

    def convert_simple_product!
      quantity = target_quantity!
      variation, _variation_created = client.find_or_create_variation(name: QUANTITY_VARIATION_NAME)
      variation_id = variation["id"]
      if variation_id.blank?
        raise Products::YampiProductPublicationService::PublicationError.new(
          "variation_id_missing",
          "A Yampi não retornou o ID da variação Quantidade."
        )
      end

      base_name = "1 unidade"
      target_name = quantity == 1 ? base_name : "#{quantity} unidades"

      base_value, _base_created = client.find_or_create_variation_value(
        variation_id: variation_id,
        name: base_name
      )
      target_value, target_created = client.find_or_create_variation_value(
        variation_id: variation_id,
        name: target_name
      )

      base_value_id = base_value["id"]
      target_value_id = target_value["id"]
      if base_value_id.blank? || target_value_id.blank?
        raise Products::YampiProductPublicationService::PublicationError.new(
          "variation_value_missing_id",
          "A Yampi não retornou os IDs dos valores da variação Quantidade."
        )
      end

      product_switched = false
      begin
        client.update_product(product_id, {
          simple: false,
          variations_ids: [ variation_id ]
        })
        product_switched = true

        client.update_sku(parent_sku.fetch("id"), base_sku_update_payload(base_name))
      rescue => e
        if product_switched
          begin
            client.update_product(product_id, { simple: true, variations_ids: [] })
          rescue => rollback_error
            Rails.logger.error(
              "[YampiVariationAxisService] rollback product=#{product_id} failed: #{rollback_error.message}"
            )
          end
        end
        raise e
      end

      verified = client.fetch_sku(parent_sku.fetch("id"))
      unless sku_has_variation_value?(verified, base_name)
        result = Result.new(converted_from_simple: true)
        rollback_conversion!(result)
        raise Products::YampiProductPublicationService::PublicationError.new(
          "base_variation_not_confirmed",
          "A Yampi não confirmou que o SKU-base passou a representar '1 unidade'. O novo SKU não foi criado."
        )
      end

      Result.new(
        variation_id: variation_id,
        variation_name: QUANTITY_VARIATION_NAME,
        target_value_id: target_value_id,
        target_value_name: target_value["name"].presence || target_name,
        target_value_created: target_created,
        converted_from_simple: true,
        base_value_id: base_value_id,
        base_value_name: base_name
      )
    end

    def base_sku_update_payload(variation_values)
      required = %w[
        product_id sku price_cost price_sale weight height width length
        quantity_managed availability availability_soldout blocked_sale
      ]
      missing = required.select { |field| !parent_sku.key?(field) || parent_sku[field].nil? }
      if missing.any?
        raise Products::YampiProductPublicationService::PublicationError.new(
          "parent_sku_incomplete_for_conversion",
          "O SKU-base não trouxe os campos necessários para converter o produto em variação: #{missing.join(', ')}. Nada foi alterado."
        )
      end

      payload = {
        product_id: parent_sku["product_id"],
        sku: parent_sku["sku"],
        price_cost: parent_sku["price_cost"],
        price_sale: parent_sku["price_sale"],
        weight: parent_sku["weight"],
        height: parent_sku["height"],
        width: parent_sku["width"],
        length: parent_sku["length"],
        quantity_managed: parent_sku["quantity_managed"],
        availability: parent_sku["availability"],
        availability_soldout: parent_sku["availability_soldout"],
        blocked_sale: parent_sku["blocked_sale"],
        variations_values_ids: Array(variation_values)
      }

      %w[erp_id barcode allow_sell_without_customization price_discount order].each do |field|
        payload[field.to_sym] = parent_sku[field] if parent_sku.key?(field) && !parent_sku[field].nil?
      end

      payload
    end

    def target_value_name
      quantity = target_quantity
      return quantity == 1 ? "1 unidade" : "#{quantity} unidades" if quantity

      registration.name.to_s.strip.presence || registration.sku
    end

    def target_quantity!
      target_quantity || raise(
        Products::YampiProductPublicationService::PublicationError.new(
          "quantity_not_inferable",
          "Para converter um produto simples em variações de Quantidade, o SKU alvo precisa seguir o padrão #{registration.parent_product.sku}_N (ex.: #{registration.parent_product.sku}_2)."
        )
      )
    end

    def target_quantity
      parent_code = registration.parent_product.sku.to_s.strip
      target_code = registration.sku.to_s.strip
      prefix = "#{parent_code}_"
      return nil unless target_code.start_with?(prefix)

      suffix = target_code.delete_prefix(prefix)
      return nil unless suffix.match?(/\A\d+\z/)

      value = suffix.to_i
      value.positive? ? value : nil
    end

    def sku_variation_axes(sku)
      normalize_relation(sku["variations"])
    end

    def product_variation_axes(product)
      normalize_relation(product["variations"])
    end

    def normalize_relation(value)
      case value
      when Array
        value.select { |item| item.is_a?(Hash) }
      when Hash
        Array(value["data"]).select { |item| item.is_a?(Hash) }
      else
        []
      end
    end

    def axis_id(axis)
      axis["id"] || axis["variation_id"]
    end

    def axis_name(axis)
      axis["name"] || axis["variation_name"]
    end

    def sku_has_variation_value?(sku, expected)
      normalize_relation(sku["variations"]).any? do |variation|
        value = variation["value"] || variation["name"] || variation["value_name"]
        value.to_s.strip.casecmp?(expected)
      end
    end

    def truthy_simple?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
