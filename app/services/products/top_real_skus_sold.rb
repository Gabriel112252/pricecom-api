module Products
  # Ranks products by REAL quantity sold: a kit sale (products.is_kit) is
  # exploded into its actual leaf components via Products::ExplodeKit —
  # never counted as "1 unit of the kit SKU". Extracted out of
  # Dashboard::BuildSummary#build_product_turnover_summary so Idworks::
  # DashboardStatsService's "SKUs reais vendidos" gadget (aba idworks) uses
  # the exact same explosion logic instead of a second, drifting copy —
  # same rationale as ProductRevenueSql/OrderRevenueSql.
  #
  # `integration_id:` (default :any, meaning no filter) narrows the RESULT
  # to a loja (Hidrabene x Anasol) — applied to each LEAF product's own
  # integration_id, AFTER explosion, not to the kit product or to
  # order_items_scope before exploding. A kit product itself isn't
  # necessarily tagged with a loja (idworks doesn't always carry a
  # kit-level SKU in its own catalog), but its real components usually
  # are — filtering order_items_scope by products.integration_id up front
  # would silently drop every kit sale from a loja-filtered result before
  # it's even exploded. Post-explosion filtering is the only place this is
  # correct for a kit whose own product record has no/different
  # integration_id than its components.
  class TopRealSkusSold
    def self.call(order_items_scope, limit: 15, integration_id: :any)
      new(order_items_scope, limit: limit, integration_id: integration_id).call
    end

    def initialize(order_items_scope, limit:, integration_id:)
      @order_items_scope = order_items_scope
      @limit = limit
      @integration_id = integration_id
    end

    def call
      combined = direct_quantities.merge(kit_quantities) { |_id, direct, kit| merge_entry(direct, kit) }

      combined.values
        .select { |entry| integration_id == :any || entry[:integration_id] == integration_id }
        .map { |entry| entry.merge(total_qty: entry[:direct_qty] + entry[:kit_qty], kit_only: entry[:direct_qty].zero? && entry[:kit_qty] > 0) }
        .sort_by { |entry| -entry[:total_qty] }
        .first(limit)
    end

    private

    attr_reader :order_items_scope, :limit, :integration_id

    # is_kit: false — a kit line itself was never a real product taken off
    # a shelf, only its components were. Pre-extraction, this method
    # summed EVERY order_item (kit lines included) here first and only
    # ADDED the exploded components afterward, without ever removing the
    # kit's own phantom entry — a kit sale showed up twice: once as
    # "KIT-1: 3 sold" (wrong — nothing named KIT-1 physically moved) and
    # once correctly exploded into its components. Fixed here since both
    # call sites (BuildSummary and Idworks::DashboardStatsService) inherit
    # it either way.
    def direct_quantities
      order_items_scope
        .where(products: { is_kit: false })
        .group("products.id", "products.sku", "products.name", "products.integration_id")
        .sum(:quantity)
        .each_with_object({}) do |((id, sku, name, product_integration_id), qty), hash|
          hash[id] = { id: id, sku: sku, name: name, integration_id: product_integration_id, direct_qty: qty.to_f, kit_qty: 0.0 }
        end
    end

    def kit_quantities
      hash = {}

      order_items_scope.where(products: { is_kit: true })
        .includes(product: { kit_components: { component_product: { kit_components: :component_product } } })
        .find_each do |item|
          Products::ExplodeKit.call(item.product, item.quantity).each do |leaf|
            product = leaf[:product]
            entry = hash[product.id] ||= {
              id: product.id, sku: product.sku, name: product.name, integration_id: product.integration_id,
              direct_qty: 0.0, kit_qty: 0.0
            }
            entry[:kit_qty] += leaf[:real_qty].to_f
          end
        end

      hash
    end

    def merge_entry(direct, kit)
      direct.merge(direct_qty: direct[:direct_qty] + kit[:direct_qty], kit_qty: direct[:kit_qty] + kit[:kit_qty])
    end
  end
end
