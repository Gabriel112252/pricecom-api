module Idworks
  # Hidrabene e Anasol compartilham a mesma conta IDWorks. A separação de
  # loja precisa acontecer pelo produto, não por Integration. Mantemos o
  # DashboardStatsService original como base e sobrescrevemos apenas os
  # recortes que dependem de loja.
  class StoreAwareDashboardStatsService < DashboardStatsService
    private

    def valid_loja?
      loja.blank? || Product::STORE_KEYS.include?(loja)
    end

    def product_scope_for_store(store_key)
      tenant.products.for_store(store_key)
    end

    def item_scope_for_store(scope, store_key)
      scope.where(products: { id: product_scope_for_store(store_key).select(:id) })
    end

    def local_order_numbers_for_store(store_key)
      tenant.orders
        .where(
          id: OrderItem
            .where(product_id: product_scope_for_store(store_key).select(:id))
            .select(:order_id)
        )
        .where.not(order_number: [ nil, "" ])
        .select(:order_number)
    end

    # Um pedido que contém produtos das duas lojas não pode ser atribuído
    # integralmente a uma delas no espelho do IDWorks, porque idworks_orders
    # guarda só o total do pedido e não as linhas. Esses pedidos ficam no
    # bucket nao_identificado no lado ERP, enquanto o lado Pricecom continua
    # repartindo a receita corretamente item a item.
    def exclusive_local_order_numbers_for_store(store_key)
      other_store = (Product::STORE_KEYS - [ store_key ]).first

      tenant.orders
        .where(order_number: local_order_numbers_for_store(store_key))
        .where.not(order_number: local_order_numbers_for_store(other_store))
        .select(:order_number)
    end

    def scoped_orders
      return base_orders_scope if loja.blank?
      return base_orders_scope.none unless valid_loja?

      base_orders_scope.where(
        id: OrderItem
          .where(product_id: product_scope_for_store(loja).select(:id))
          .select(:order_id)
      )
    end

    def revenue_by_loja
      result = Product::STORE_KEYS.index_with do |store_key|
        item_scope_for_store(item_scope_in_period, store_key)
          .sum(Arel.sql(item_revenue_amount_sql))
          .to_f
          .round(2)
      end
      result[UNMAPPED_LOJA_KEY] = 0.0
      result
    end

    def top_products
      return [] if loja.present? && !valid_loja?

      scope = item_scope_in_period
      scope = item_scope_for_store(scope, loja) if loja.present?

      rows = scope
        .group("products.id", "products.sku", "products.name")
        .order(Arel.sql("SUM(order_items.quantity) DESC"))
        .limit(TOP_PRODUCTS_LIMIT)
        .pluck(
          Arel.sql("products.sku"),
          Arel.sql("products.name"),
          Arel.sql("SUM(order_items.quantity)"),
          Arel.sql("SUM(#{item_revenue_amount_sql})")
        )

      rows.map do |sku, name, quantity, revenue|
        { sku: sku, name: name, quantity: quantity.to_f, revenue: revenue.to_f.round(2) }
      end
    end

    def real_skus_sold
      return super if loja.blank?
      return [] unless valid_loja?

      # TopRealSkusSold explode kits antes de devolver os produtos reais.
      # Pedimos o conjunto completo e só então aplicamos a classificação da
      # loja ao produto folha, preservando vendas de kits mistos.
      ranked = Products::TopRealSkusSold.call(
        item_scope_in_period,
        limit: [ tenant.products.count, TOP_PRODUCTS_LIMIT ].max,
        integration_id: :any
      )

      ranked = ranked
        .select { |entry| Product.store_key_for(entry[:name]) == loja }
        .first(TOP_PRODUCTS_LIMIT)

      breakdown_by_product = channel_breakdown_by_product_id
      ranked.map { |entry| entry.merge(channel_breakdown: breakdown_by_product[entry[:id]] || []) }
    end

    def idworks_orders_scope
      scope = tenant.idworks_orders.where(recorded_at: period_from.beginning_of_day..period_to.end_of_day)
      return scope if loja.blank?
      return scope.none unless valid_loja?

      scope.where(order_number: exclusive_local_order_numbers_for_store(loja))
    end

    def idworks_revenue_total
      return super if loja.blank?
      return 0.0 unless valid_loja?

      idworks_orders_scope.sum(Arel.sql(idworks_revenue_sql)).to_f.round(2)
    end

    def idworks_revenue_by_loja
      base = tenant.idworks_orders.where(recorded_at: period_from.beginning_of_day..period_to.end_of_day)
      total = base.sum(Arel.sql(idworks_revenue_sql)).to_f

      result = Product::STORE_KEYS.index_with do |store_key|
        base
          .where(order_number: exclusive_local_order_numbers_for_store(store_key))
          .sum(Arel.sql(idworks_revenue_sql))
          .to_f
          .round(2)
      end

      identified = result.values.sum
      result[UNMAPPED_LOJA_KEY] = [ total - identified, 0.0 ].max.round(2)
      result
    end
  end
end
