require "rails_helper"

RSpec.describe Reconciliation::OrderReconciliationService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:integration) do
    tenant.integrations.create!(provider: "idworks", name: "idworks", status: "connected", credentials: {})
  end
  let(:period_from) { 6.days.ago.to_date }
  let(:period_to)   { Date.current }

  before { integration } # garante a Integration criada antes de cada exemplo, exceto no describe de skip

  def fake_fetcher(result)
    Class.new do
      define_singleton_method(:call) { |*, **| result }
    end
  end

  def exploding_fetcher
    Class.new do
      define_singleton_method(:call) { |*, **| raise "fetcher não deveria ter sido chamado" }
    end
  end

  def make_order
    tenant.orders.create!(
      channel: channel, external_id: "order-#{SecureRandom.hex(4)}", order_number: "N1",
      order_type: "sale", gross_value: 100, margin: 10, ordered_at: 1.day.ago
    )
  end

  def call_service(threshold_pct: 5.0, idworks_qty_by_sku: {})
    described_class.call(
      tenant: tenant, period_from: period_from, period_to: period_to,
      threshold_pct: threshold_pct, idworks_fetcher: fake_fetcher(idworks_qty_by_sku)
    )
  end

  describe "decomposição de kit multi-componente" do
    it "compara pelos SKUs base dos componentes, nunca pelo SKU literal do kit" do
      sabonete = tenant.products.create!(sku: "SABONETE", name: "Sabonete", cost_price: 5)
      protetor = tenant.products.create!(sku: "PROTETOR", name: "Protetor", cost_price: 5)
      serum    = tenant.products.create!(sku: "SERUM", name: "Sérum", cost_price: 5)
      kit      = tenant.products.create!(sku: "KIT044", name: "Kit", is_kit: true, cost_price: 0)
      kit.kit_components.create!(component_product: sabonete, quantity: 1)
      kit.kit_components.create!(component_product: protetor, quantity: 1)
      kit.kit_components.create!(component_product: serum, quantity: 1)

      order = make_order
      order.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 3, unit_price: 100, unit_cost: 60)

      result = call_service

      expect(result.success?).to eq(true)
      %w[SABONETE PROTETOR SERUM].each do |sku|
        expect(ReconciliationItem.find_by(tenant: tenant, sku: sku).pricecom_qty).to eq(3)
      end
      expect(ReconciliationItem.find_by(tenant: tenant, sku: "KIT044")).to be_nil
    end
  end

  describe "decomposição de pack (multiplicador por sufixo)" do
    it "multiplica a quantidade vendida do pack pelo componente por unidade" do
      base = tenant.products.create!(sku: "2080", name: "Produto base", cost_price: 5)
      pack = tenant.products.create!(sku: "2080_3", name: "Pack 3un", is_kit: true, cost_price: 0)
      pack.kit_components.create!(component_product: base, quantity: 3)

      order = make_order
      order.order_items.create!(product: pack, sku: pack.sku, name: pack.name, quantity: 2, unit_price: 100, unit_cost: 60)

      call_service

      expect(ReconciliationItem.find_by(tenant: tenant, sku: "2080").pricecom_qty).to eq(6) # 2 packs x 3un
      expect(ReconciliationItem.find_by(tenant: tenant, sku: "2080_3")).to be_nil
    end
  end

  describe "cálculo de diff/diff_pct" do
    it "calcula diff_qty e diff_pct relativos ao idworks_qty" do
      product = tenant.products.create!(sku: "SKU-A", name: "Produto A", cost_price: 5)
      order = make_order
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 10, unit_price: 10, unit_cost: 5)

      call_service(idworks_qty_by_sku: { "SKU-A" => 8 })

      item = ReconciliationItem.find_by(tenant: tenant, sku: "SKU-A")
      expect(item.idworks_qty).to eq(8)
      expect(item.pricecom_qty).to eq(10)
      expect(item.diff_qty).to eq(2)
      expect(item.diff_pct).to eq(BigDecimal("25.0")) # (10-8)/8 * 100
    end

    it "deixa diff_pct nulo quando idworks_qty é zero, mas ainda marca como divergente" do
      product = tenant.products.create!(sku: "SKU-B", name: "Produto B", cost_price: 5)
      order = make_order
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 5, unit_price: 10, unit_cost: 5)

      call_service

      item = ReconciliationItem.find_by(tenant: tenant, sku: "SKU-B")
      expect(item.idworks_qty).to eq(0)
      expect(item.diff_pct).to be_nil
      expect(item.unmatched_in_idworks?).to eq(true)
      expect(item.divergent?(5.0)).to eq(true)
    end

    it "inclui SKU que só existe no idworks (pricecom_qty zero)" do
      call_service(idworks_qty_by_sku: { "SKU-ONLY-IDWORKS" => 4 })

      item = ReconciliationItem.find_by(tenant: tenant, sku: "SKU-ONLY-IDWORKS")
      expect(item.pricecom_qty).to eq(0)
      expect(item.diff_qty).to eq(-4)
      expect(item.unmatched_in_idworks?).to eq(false) # existe no idworks, é o Pricecom que não vendeu
    end
  end

  describe "idempotência" do
    it "rodar 2x no mesmo período faz upsert em vez de duplicar" do
      product = tenant.products.create!(sku: "SKU-A", name: "Produto A", cost_price: 5)
      order = make_order
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 10, unit_price: 10, unit_cost: 5)

      2.times { call_service(idworks_qty_by_sku: { "SKU-A" => 10 }) }

      expect(ReconciliationItem.where(tenant: tenant, sku: "SKU-A").count).to eq(1)
    end
  end

  describe "sincronização de AuditConflict" do
    it "cria order_qty_mismatch quando diff_pct estoura o threshold" do
      product = tenant.products.create!(sku: "SKU-A", name: "Produto A", cost_price: 5)
      order = make_order
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 20, unit_price: 10, unit_cost: 5)

      call_service(threshold_pct: 5.0, idworks_qty_by_sku: { "SKU-A" => 10 }) # diff_pct = 100%

      conflict = tenant.audit_conflicts.find_by(conflict_type: "order_qty_mismatch")
      expect(conflict).to be_present
      expect(conflict.status).to eq("open")
      expect(conflict.metadata["sku"]).to eq("SKU-A")
      expect(conflict.product).to eq(product)
    end

    it "resolve o conflito automaticamente quando a divergência volta a ficar dentro do threshold" do
      product = tenant.products.create!(sku: "SKU-A", name: "Produto A", cost_price: 5)
      order = make_order
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 20, unit_price: 10, unit_cost: 5)

      call_service(threshold_pct: 5.0, idworks_qty_by_sku: { "SKU-A" => 10 })
      conflict = tenant.audit_conflicts.find_by(conflict_type: "order_qty_mismatch")
      expect(conflict.status).to eq("open")

      call_service(threshold_pct: 5.0, idworks_qty_by_sku: { "SKU-A" => 20 })
      expect(conflict.reload.status).to eq("resolved")
    end

    it "não cria conflito quando a divergência está dentro do threshold" do
      product = tenant.products.create!(sku: "SKU-A", name: "Produto A", cost_price: 5)
      order = make_order
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 10, unit_price: 10, unit_cost: 5)

      call_service(threshold_pct: 5.0, idworks_qty_by_sku: { "SKU-A" => 10 })

      expect(tenant.audit_conflicts.where(conflict_type: "order_qty_mismatch")).to be_empty
    end
  end

  describe "quando idworks não está conectado" do
    it "retorna outcome skipped sem chamar o fetcher" do
      integration.update!(status: "disconnected")

      result = described_class.call(
        tenant: tenant, period_from: period_from, period_to: period_to,
        idworks_fetcher: exploding_fetcher
      )

      expect(result.skipped?).to eq(true)
    end
  end
end
