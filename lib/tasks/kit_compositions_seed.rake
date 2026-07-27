namespace :kit_compositions do
  # Kits/variações de pack identificados numa reconciliação manual contra o
  # idworks (2026-07-27) — precisavam existir em KitComponent para que a
  # decomposição de vendas (Products::ExplodeKit, usada pelo
  # Reconciliation::OrderReconciliationService) pare de comparar essas
  # vendas pelo SKU literal do kit/pack, que nunca aparece faturado como tal
  # na nota fiscal do idworks (o ERP fatura os componentes reais).
  #
  # Componentes de KIT044/KIT077 confirmados 2026-07-27 contra dados reais
  # do idworks (GET /orders?SkuView=1, tenant hidrabene): um pedido com
  # KitIDSkuCompany="KIT044" trazia exatamente estes 3 IDSkuCompany como
  # itens — "2080" (protetor solar facial clareador), "0109" (sérum
  # multicorretivo), "0107" (sabonete líquido facial). Não são mais
  # placeholders.
  KIT_MAP = {
    "KIT044" => { "0107" => 1, "2080" => 1, "0109" => 1 },
    "KIT044_2un" => { "0107" => 2, "2080" => 2, "0109" => 2 },
    "KIT044_3un" => { "0107" => 3, "2080" => 3, "0109" => 3 },
    "KIT077" => { "0107" => 1, "2080" => 1, "0109" => 1 },

    "2080_1" => { "2080" => 1 },
    "2080_2" => { "2080" => 2 },
    "2080_3" => { "2080" => 3 },
    "2080_6" => { "2080" => 6 },
    "2080_10" => { "2080" => 10 },

    "1un_0109" => { "0109" => 1 },
    "2un_0109" => { "0109" => 2 },
    "3un_0109" => { "0109" => 3 },

    "0107_1" => { "0107" => 1 },
    "0107_2" => { "0107" => 2 },
    "0107_3" => { "0107" => 3 }
  }.freeze

  PLACEHOLDER_PREFIX = "TODO_"

  desc "Popula KitComponent para os kits/packs identificados na reconciliação idworks x Pricecom. " \
       "Uso: TENANT_SLUG=xxx bin/rails kit_compositions:seed"
  task seed: :environment do
    slug = ENV["TENANT_SLUG"]
    abort "Defina TENANT_SLUG=<slug do tenant>" if slug.blank?

    tenant = Tenant.find_by(slug: slug)
    abort "Tenant não encontrado para slug=#{slug}" unless tenant

    pending_placeholders = KIT_MAP.values.flat_map(&:keys).uniq.select { |sku| sku.start_with?(PLACEHOLDER_PREFIX) }
    if pending_placeholders.any?
      abort <<~MSG
        Preencha os SKUs reais antes de rodar — ainda há placeholder(s) em KIT_MAP (lib/tasks/kit_compositions_seed.rake):
        #{pending_placeholders.join(", ")}
      MSG
    end

    created = 0
    updated = 0
    skipped_missing_sku = []

    KIT_MAP.each do |kit_sku, components|
      kit_product = tenant.products.find_by(sku: kit_sku)
      unless kit_product
        skipped_missing_sku << kit_sku
        next
      end

      kit_product.update!(is_kit: true) unless kit_product.is_kit?

      components.each do |component_sku, quantity|
        component_product = tenant.products.find_by(sku: component_sku)
        unless component_product
          skipped_missing_sku << component_sku
          next
        end

        kit_component = KitComponent.find_or_initialize_by(kit_product: kit_product, component_product: component_product)
        kit_component.quantity = quantity
        if kit_component.new_record?
          created += 1
        elsif kit_component.quantity_changed?
          updated += 1
        end
        kit_component.save!
      end
    end

    puts "Done. #{created} KitComponent criado(s), #{updated} atualizado(s)."
    puts "SKU(s) não encontrado(s) no cadastro (pulados): #{skipped_missing_sku.uniq.join(', ')}" if skipped_missing_sku.any?
  end
end
