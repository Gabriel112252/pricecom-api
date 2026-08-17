module Idworks
  # Builds the payload for the "idworks" dashboard tab (Api::V1::
  # IdworksDashboardController) — revenue/orders/top products/channel mix
  # for a period, optionally cut by loja (Hidrabene x Anasol).
  #
  # There's no explicit loja column anywhere (see products.integration_id's
  # migration comment): a product's loja is whichever idworks Integration
  # (provider: "idworks", one per company — Integration#name is unique per
  # provider) last synced its cost/catalog via
  # Integrations::Idworks::ProductCostSyncService. Orders don't carry a loja
  # of their own; an order's loja is derived from the products in its items.
  # An order with items from more than one loja (should be rare — Hidrabene
  # and Anasol are separate catalogs/storefronts) counts under both when
  # filtering, and its revenue is split at the item level in revenue_by_loja.
  #
  # Reuses the exact same revenue rules as the rest of the dashboard
  # (Dashboard::OrderRevenueSql/ProductRevenueSql) so this tab isn't a
  # second, drifting definition of "receita" — same TikTok gross-vs-net
  # handling, same UNPAID/status_unknown exclusion via Order.sales_and_refunds.
  class DashboardStatsService
    include Dashboard::ProductRevenueSql
    include Dashboard::OrderRevenueSql

    LOJAS = %w[hidrabene anasol].freeze
    UNMAPPED_LOJA_KEY = "nao_identificado".freeze
    TOP_PRODUCTS_LIMIT = 10

    # channel_breakdown (só nesta aba — as outras continuam via
    # channels.platform, a integração própria do Pricecom, que não cobre
    # canal sem integração direta como Mercado Livre) agrupa por
    # orders.idworks_sales_channel em vez de channels.name. Esse campo vem
    # do filename de SalesChannelLogoUrl no payload do idworks (ver
    # IdworksAdapter#extract_channel_slug) — CONFIRMADO 2026-08-17 contra
    # payload real: shopify/tiktok/shopee/mercadolivre, nada além disso
    # visto até agora.
    #
    # "shopify" tem uma regra extra confirmada com o Gabriel: Yampi é o
    # checkout que passou a rodar em cima do Shopify a partir dessa data —
    # pedido "shopify" ANTES do corte continua "Shopify" (nomenclatura
    # antiga), a partir do corte (inclusive) vira "Yampi". A data usada pro
    # corte é orders.ordered_at — o mesmo campo que já delimita todo o
    # resto do período nesta classe (base_orders_scope), não
    # Recordtimestamp do idworks (que o próprio IdworksAdapter documenta
    # como possivelmente um "last modified", não a data real do pedido).
    SHOPIFY_TO_YAMPI_CUTOFF = Date.new(2026, 6, 15).freeze
    IDWORKS_CHANNEL_DISPLAY_NAMES = {
      "tiktok"       => "TikTok Shop",
      "shopee"       => "Shopee",
      "mercadolivre" => "Mercado Livre",
      "shopify"      => "Shopify",
      "yampi"        => "Yampi"
    }.freeze
    UNMAPPED_CHANNEL_KEY = "nao_identificado".freeze
    UNMAPPED_CHANNEL_DISPLAY_NAME = "Não identificado".freeze

    Result = Struct.new(
      :revenue_total, :orders_count, :average_ticket, :revenue_by_loja,
      :orders_timeseries, :top_products, :channel_breakdown, :real_skus_sold,
      keyword_init: true
    )

    def self.call(tenant:, period_from:, period_to:, loja: nil)
      new(tenant: tenant, period_from: period_from, period_to: period_to, loja: loja).call
    end

    def initialize(tenant:, period_from:, period_to:, loja: nil)
      @tenant = tenant
      @period_from = period_from.to_date
      @period_to = period_to.to_date
      @loja = loja.presence
    end

    def call
      Result.new(
        revenue_total:     revenue_total,
        orders_count:      orders_count,
        average_ticket:    average_ticket,
        revenue_by_loja:   revenue_by_loja,
        orders_timeseries: orders_timeseries,
        top_products:      top_products,
        channel_breakdown: channel_breakdown,
        real_skus_sold:    real_skus_sold
      )
    end

    private

    attr_reader :tenant, :period_from, :period_to, :loja

    def base_orders_scope
      tenant.orders
        .where(ordered_at: period_from.beginning_of_day..period_to.end_of_day)
        .merge(Order.sales_and_refunds)
    end

    # Orders scope narrowed to `loja` (blank = every order in the period).
    def scoped_orders
      return base_orders_scope if loja.blank?

      integration = integration_for_loja(loja)
      return base_orders_scope.none unless integration

      base_orders_scope.where(id: OrderItem.joins(:product).where(products: { integration_id: integration.id }).select(:order_id))
    end

    # order_items -> products -> channels, same base every per-item query
    # here needs (top_products, revenue_by_loja) — mirrors
    # Dashboard::BuildSummary#build_top_products_by_revenue's scope.
    def item_scope_in_period
      OrderItem
        .joins(:product, order: :channel)
        .merge(Order.sales_and_refunds)
        .where(order_id: base_orders_scope.select(:id))
        .where(is_gift: false)
        .where(item_discount_split_reliable_sql)
    end

    def integration_for_loja(loja_key)
      @integrations_by_loja ||= {}
      return @integrations_by_loja[loja_key] if @integrations_by_loja.key?(loja_key)

      @integrations_by_loja[loja_key] = find_integration_for_loja(loja_key)
    end

    # Anasol: the idworks integration named after it (e.g. "idworks Anasol"
    # — set at connect time on the Integrations screen). Hidrabene: any
    # other idworks integration (there's only ever been one so far, and
    # it's the tenant's own original account — see db/seeds.rb).
    def find_integration_for_loja(loja_key)
      scope = tenant.integrations.where(provider: "idworks")

      case loja_key
      when "anasol"
        scope.where("integrations.name ILIKE ?", "%anasol%").first
      when "hidrabene"
        scope.where.not("integrations.name ILIKE ?", "%anasol%").first
      end
    end

    def revenue_total
      scoped_orders.joins(:channel).sum(Arel.sql(effective_revenue_sql)).to_f.round(2)
    end

    def orders_count
      scoped_orders.count
    end

    def average_ticket
      count = orders_count
      count.positive? ? (revenue_total / count).round(2) : nil
    end

    # Sempre a repartição completa (ignora o filtro `loja`) — é o que os
    # cards "por loja" mostram independente do que está selecionado.
    def revenue_by_loja
      rows = item_scope_in_period
        .group("products.integration_id")
        .pluck(Arel.sql("products.integration_id"), Arel.sql("SUM(#{item_revenue_amount_sql})"))

      revenue_by_integration_id = rows.each_with_object({}) { |(integration_id, revenue), hash| hash[integration_id] = revenue.to_f.round(2) }

      # &.id would otherwise resolve a NOT-YET-CONNECTED loja to the same
      # nil key as "produto nunca sincronizado pelo idworks" below — an
      # unconnected loja must read as 0.0, not steal the untagged bucket.
      result = LOJAS.index_with do |loja_key|
        integration = integration_for_loja(loja_key)
        integration ? (revenue_by_integration_id[integration.id] || 0.0) : 0.0
      end
      result[UNMAPPED_LOJA_KEY] = revenue_by_integration_id[nil] || 0.0
      result
    end

    # Volume de pedidos por dia x canal (respeita o filtro `loja`) — mesmo
    # formato de summary.orders.by_channel_series, reaproveitado por
    # OrderVolumeChart no frontend.
    def orders_timeseries
      rows = scoped_orders
        .joins(:channel)
        .group(Arel.sql("DATE(orders.ordered_at)"), "channels.name")
        .count

      rows.map { |(date, channel), count| { date: date.to_date.iso8601, channel: channel, count: count } }
        .sort_by { |row| row[:date] }
    end

    def top_products
      return [] if loja.present? && integration_for_loja(loja).nil?

      scope = item_scope_in_period
      scope = scope.where(products: { integration_id: integration_for_loja(loja).id }) if loja.present?

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

      rows.map { |sku, name, quantity, revenue| { sku: sku, name: name, quantity: quantity.to_f, revenue: revenue.to_f.round(2) } }
    end

    # "SKUs reais vendidos" — diferente de top_products acima (que ranqueia
    # pelo SKU literal do order_item, kit incluído como se fosse 1 unidade
    # do próprio kit): aqui uma venda de kit é explodida nos componentes
    # que de fato saíram do estoque, via Products::TopRealSkusSold (mesma
    # lógica de Dashboard::BuildSummary#build_product_turnover_summary,
    # compartilhada — não uma segunda cópia). integration_id vai
    # DEPOIS da explosão (ver comentário da classe) — não dá pra filtrar
    # order_items_scope por products.integration_id antes de explodir sem
    # arriscar descartar a venda inteira de um kit sem loja própria.
    #
    # channel_breakdown por linha (planilha externa aprovada pelo Gabriel
    # pede "por marca: ranking de produtos + breakdown por canal" — faltava
    # cruzar produto x canal, só existia agregado em #channel_breakdown
    # acima) — cada produto ganha sua própria repartição por canal nativo
    # do idworks (com avulso/kit/receita já cruzados também, ver
    # #channel_breakdown_by_product_id), calculada uma vez e reaproveitada
    # por linha do ranking.
    def real_skus_sold
      return [] if loja.present? && integration_for_loja(loja).nil?

      integration_id = loja.present? ? integration_for_loja(loja).id : :any
      ranked = Products::TopRealSkusSold.call(item_scope_in_period, limit: TOP_PRODUCTS_LIMIT, integration_id: integration_id)
      breakdown_by_product = channel_breakdown_by_product_id

      ranked.map { |entry| entry.merge(channel_breakdown: breakdown_by_product[entry[:id]] || []) }
    end

    # {product_id => [{channel:, direct_qty:, kit_qty:, quantity:, revenue:}]}
    # — cruza as 3 dimensões que antes só existiam separadas (canal nativo
    # do idworks, e avulso/kit de Products::TopRealSkusSold/ExplodeKit).
    # Sempre a repartição completa (todo produto, todo canal) — real_skus_sold
    # acima só usa as entradas dos produtos que já estão no ranking loja-filtrado.
    #
    # Parte "avulso" (is_kit: false) é uma única agregação SQL — reaproveita
    # #idworks_channel_key_sql e item_revenue_amount_sql direto, sem
    # reimplementar o CASE em Ruby. Parte "em kit" precisa de Ruby mesmo
    # (Products::ExplodeKit é recursivo, não dá pra expressar em SQL) — o
    # canal aí vem de #idworks_channel_display_name_for, que replica a
    # MESMA regra de #idworks_channel_key_sql pra um Order já carregado em
    # memória, então as duas nunca podem divergir sem os testes pegarem
    # (ver spec "concorda com channel_breakdown do agregado").
    #
    # Receita "aproximada" pro componente explodido de um kit: o
    # order_item do kit só tem UM valor de venda pra tudo que veio junto
    # (ex: "Kit Clareador" vendido por R$150, sem preço individual por
    # componente registrado em lugar nenhum) — a única forma de atribuir
    # receita a cada componente sem inventar um preço é ratear
    # proporcionalmente à quantidade real que aquele componente representa
    # na explosão daquela venda. É uma aproximação por construção — dado
    # daí o nome da coluna na UI ("Receita Aproximada"), não um valor
    # contábil exato.
    def channel_breakdown_by_product_id
      acc = Hash.new { |hash, key| hash[key] = Hash.new { |inner, channel| inner[channel] = { direct_qty: 0.0, kit_qty: 0.0, revenue: 0.0 } } }

      item_scope_in_period.where(products: { is_kit: false })
        .group("products.id", Arel.sql(idworks_channel_key_sql))
        .pluck(Arel.sql("products.id"), Arel.sql(idworks_channel_key_sql), Arel.sql("SUM(order_items.quantity)"), Arel.sql("SUM(#{item_revenue_amount_sql})"))
        .each do |product_id, channel_key, qty, revenue|
          entry = acc[product_id][IDWORKS_CHANNEL_DISPLAY_NAMES.fetch(channel_key, UNMAPPED_CHANNEL_DISPLAY_NAME)]
          entry[:direct_qty] += qty.to_f
          entry[:revenue] += revenue.to_f
        end

      item_scope_in_period.where(products: { is_kit: true })
        .select("order_items.*", "(#{item_revenue_amount_sql}) AS computed_item_revenue")
        .includes(:order, product: { kit_components: { component_product: { kit_components: :component_product } } })
        .find_each do |item|
          channel = idworks_channel_display_name_for(item.order)
          leaves = Products::ExplodeKit.call(item.product, item.quantity)
          total_real_units = leaves.sum { |leaf| leaf[:real_qty].to_f }
          item_revenue = item.computed_item_revenue.to_f

          leaves.each do |leaf|
            share = total_real_units.positive? ? (leaf[:real_qty].to_f / total_real_units) : 0.0
            entry = acc[leaf[:product].id][channel]
            entry[:kit_qty] += leaf[:real_qty].to_f
            entry[:revenue] += item_revenue * share
          end
        end

      acc.transform_values do |by_channel|
        by_channel.map do |channel, values|
          {
            channel:    channel,
            direct_qty: values[:direct_qty].round(2),
            kit_qty:    values[:kit_qty].round(2),
            quantity:   (values[:direct_qty] + values[:kit_qty]).round(2),
            revenue:    values[:revenue].round(2)
          }
        end.sort_by { |row| -row[:quantity] }
      end
    end

    # Mesmo mapeamento de #idworks_channel_key_sql (shopify pré/pós corte
    # vira Shopify/Yampi, slug desconhecido ou nulo vira "não identificado"),
    # em Ruby — aqui já temos o Order carregado (não uma agregação SQL),
    # então não precisa do CASE bruto.
    def idworks_channel_display_name_for(order)
      slug = order.idworks_sales_channel
      return UNMAPPED_CHANNEL_DISPLAY_NAME if slug.blank?

      key = (slug == "shopify" && order.ordered_at >= SHOPIFY_TO_YAMPI_CUTOFF.beginning_of_day) ? "yampi" : slug
      IDWORKS_CHANNEL_DISPLAY_NAMES.fetch(key, UNMAPPED_CHANNEL_DISPLAY_NAME)
    end

    # Canal nativo do idworks (orders.idworks_sales_channel), não
    # channels.name/Pricecom — ver o comentário de IDWORKS_CHANNEL_DISPLAY_NAMES
    # acima pra por quê. Ainda precisa de .joins(:channel) só porque
    # effective_revenue_sql (compartilhado com o resto do dashboard, não
    # duplicado aqui) depende de channels.platform pra saber se é TikTok.
    # Todo pedido cai em algum grupo (ELSE do CASE), nunca fica de fora da
    # soma — ver spec de regressão "nenhum pedido cai fora do agrupamento".
    def channel_breakdown
      rows = scoped_orders
        .joins(:channel)
        .group(Arel.sql(idworks_channel_key_sql))
        .pluck(
          Arel.sql(idworks_channel_key_sql),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(#{effective_revenue_sql}), 0)")
        )

      total_revenue = rows.sum { |_, _, revenue| revenue.to_f }

      rows.filter_map do |key, count, revenue|
        count_i = count.to_i
        next if count_i.zero?

        revenue_f = revenue.to_f.round(2)
        {
          channel:          IDWORKS_CHANNEL_DISPLAY_NAMES.fetch(key, UNMAPPED_CHANNEL_DISPLAY_NAME),
          orders_count:     count_i,
          net_revenue:      revenue_f,
          average_ticket:   count_i.positive? ? (revenue_f / count_i).round(2) : nil,
          share_percentage: total_revenue.positive? ? (revenue_f / total_revenue * 100).round(2) : 0
        }
      end.sort_by { |row| -row[:net_revenue] }
    end

    # Chave crua de agrupamento — "shopify" antes do corte, "yampi" a
    # partir dele (inclusive), os outros 3 slugs conhecidos como vieram,
    # qualquer coisa fora disso (nil, slug desconhecido) cai no bucket
    # "não identificado". Mapeamento pro nome de exibição fica em
    # IDWORKS_CHANNEL_DISPLAY_NAMES — evita nome acentuado ("Mercado
    # Livre") dentro de SQL bruto.
    def idworks_channel_key_sql
      quoted_cutoff = ActiveRecord::Base.connection.quote(SHOPIFY_TO_YAMPI_CUTOFF.beginning_of_day)
      known_slugs = (IDWORKS_CHANNEL_DISPLAY_NAMES.keys - [ "yampi" ]).map { |slug| ActiveRecord::Base.connection.quote(slug) }.join(", ")

      "CASE " \
        "WHEN orders.idworks_sales_channel = 'shopify' AND orders.ordered_at >= #{quoted_cutoff} THEN 'yampi' " \
        "WHEN orders.idworks_sales_channel IN (#{known_slugs}) THEN orders.idworks_sales_channel " \
        "ELSE #{ActiveRecord::Base.connection.quote(UNMAPPED_CHANNEL_KEY)} END"
    end
  end
end
