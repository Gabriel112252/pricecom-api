require "rails_helper"

RSpec.describe Financials::PagarmePayableSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:financial_source) do
    tenant.financial_sources.create!(
      provider: "pagarme",
      name: "Pagar.me",
      source_type: "gateway",
      status: "active",
      credentials: { api_key: "sk_test_abc123" },
      settings: { recipient_id: "rp_1" }
    )
  end
  let(:payables_url) { "https://api.pagar.me/core/v5/payables" }
  let(:orders_url) { "https://api.pagar.me/core/v5/orders" }
  let!(:order_by_charge) do
    tenant.orders.create!(
      channel: channel,
      external_id: "YAMPI-555001",
      order_number: "555001",
      ordered_at: Time.zone.parse("2026-07-10T10:00:00Z"),
      gross_value: 199.90,
      order_type: "sale"
    )
  end
  let!(:order_by_transaction) do
    tenant.orders.create!(
      channel: channel,
      external_id: "YAMPI-555002",
      order_number: "555002",
      ordered_at: Time.zone.parse("2026-07-11T10:00:00Z"),
      gross_value: 50.00,
      order_type: "sale"
    )
  end
  let!(:legacy_settlement) do
    financial_source.financial_settlements.create!(
      tenant: tenant,
      channel: channel,
      external_id: "legacy-charges",
      period_start: Date.new(2026, 7, 1),
      period_end: Date.new(2026, 7, 15),
      status: "paid"
    )
  end
  let!(:legacy_charge_item) do
    legacy_settlement.financial_settlement_items.create!(
      tenant: tenant,
      order: order_by_charge,
      external_id: "ch_charge_lookup",
      external_order_id: order_by_charge.external_id,
      transaction_type: "sale",
      gross_amount: 199.90,
      net_amount: 199.90,
      status: "matched"
    )
  end
  let!(:legacy_transaction_item) do
    legacy_settlement.financial_settlement_items.create!(
      tenant: tenant,
      order: order_by_transaction,
      external_id: "legacy-transaction-link",
      external_order_id: order_by_transaction.external_id,
      transaction_type: "sale",
      gross_amount: 50.00,
      net_amount: 50.00,
      status: "matched",
      metadata: { "pagarme_transaction_id" => "tran_fallback_lookup" }
    )
  end
  let(:page_1) do
    {
      data: [
        {
          id: "pay_charge",
          status: "waiting_funds",
          amount: 19990,
          fee: 1000,
          anticipation_fee: 550,
          installment: 1,
          transaction_id: "tran_charge",
          charge_id: "ch_charge_lookup",
          recipient_id: "rp_1",
          payment_date: "2026-07-20",
          original_payment_date: "2026-08-01",
          payment_method: "credit_card",
          accrual_date: "2026-07-10T12:00:00Z",
          date_created: "2026-07-10T12:00:01Z"
        }
      ],
      paging: { forward_cursor: "cursor_2" }
    }.to_json
  end
  let(:page_2) do
    {
      data: [
        {
          id: "pay_transaction",
          status: "paid",
          amount: 5000,
          fee: 125,
          anticipation_fee: 0,
          installment: 1,
          transaction_id: "tran_fallback_lookup",
          recipient_id: "rp_1",
          payment_date: "2026-07-21",
          original_payment_date: "2026-07-21",
          payment_method: "pix",
          accrual_date: "2026-07-11T12:00:00Z",
          date_created: "2026-07-11T12:00:01Z"
        }
      ],
      paging: { forward_cursor: nil }
    }.to_json
  end

  before do
    travel_to Time.zone.parse("2026-07-15T12:00:00Z")

    stub_request(:get, payables_url)
      .with(query: { "payment_date_since" => "2026-07-01", "payment_date_until" => "2026-07-31", "recipient_id" => "rp_1", "size" => "1000" })
      .to_return(status: 200, body: page_1, headers: { "Content-Type" => "application/json" })

    stub_request(:get, payables_url)
      .with(query: { "payment_date_since" => "2026-07-01", "payment_date_until" => "2026-07-31", "recipient_id" => "rp_1", "size" => "1000", "forward_cursor" => "cursor_2" })
      .to_return(status: 200, body: page_2, headers: { "Content-Type" => "application/json" })

    # Mapa charge_id → external_order_id via /orders: vazio por padrão nos
    # testes existentes, que continuam exercitando os fallbacks antigos
    # (order_from_charge_id/order_from_transaction_id via legacy_charge_item/
    # legacy_transaction_item) exatamente como antes.
    stub_request(:get, orders_url)
      .with(query: hash_including("created_since" => "2026-06-01", "created_until" => "2026-07-31"))
      .to_return(status: 200, body: { data: [], paging: { next: nil } }.to_json, headers: { "Content-Type" => "application/json" })
  end

  after { travel_back }

  it "upserts payables idempotently and links orders by charge_id then transaction_id fallback" do
    result = described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")

    expect(result.success?).to eq(true)
    expect(result.created_count).to eq(2)
    expect(result.updated_count).to eq(0)
    expect(FinancialReceivable.where(tenant: tenant).count).to eq(2)

    charge_receivable = FinancialReceivable.find_by!(payable_id: "pay_charge")
    expect(charge_receivable.order).to eq(order_by_charge)
    expect(charge_receivable.financial_settlement_item.order).to eq(order_by_charge)
    expect(charge_receivable.fee_amount).to eq(BigDecimal("10.0"))
    expect(charge_receivable.anticipation_fee_amount).to eq(BigDecimal("5.5"))
    expect(charge_receivable.net_amount).to eq(BigDecimal("184.4"))
    expect(charge_receivable.financial_settlement_item.fee_amount).to eq(BigDecimal("15.5"))

    transaction_receivable = FinancialReceivable.find_by!(payable_id: "pay_transaction")
    expect(transaction_receivable.order).to eq(order_by_transaction)
    expect(transaction_receivable.financial_settlement_item.order).to eq(order_by_transaction)
  end

  it "does not duplicate payables or settlement items on a repeated sync" do
    described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")
    result = described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")

    expect(result.created_count).to eq(0)
    expect(result.updated_count).to eq(2)
    expect(FinancialReceivable.where(tenant: tenant).count).to eq(2)
    expect(FinancialSettlementItem.where(tenant: tenant, external_id: [ "pay_charge", "pay_transaction" ]).count).to eq(2)
  end

  it "logs the payable sync window" do
    described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")

    log = IntegrationSyncLog.where(tenant: tenant, action: "pagarme_payable_sync").last
    expect(log.status).to eq("success")
    expect(log.metadata["created_count"]).to eq(2)
    expect(log.metadata["from"]).to eq("2026-07-01")
    expect(log.metadata["to"]).to eq("2026-07-31")
  end

  it "passes recipient_id persisted in FinancialSource settings to Pagar.me" do
    described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")

    expect(WebMock).to have_requested(:get, payables_url)
      .with(query: hash_including("recipient_id" => "rp_1"))
  end

  it "fetches /orders with created_since widened by the order lookback, ahead of the payment_date window" do
    described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")

    expect(WebMock).to have_requested(:get, orders_url)
      .with(query: hash_including("created_since" => "2026-06-01", "created_until" => "2026-07-31"))
  end

  describe "order linking via /orders (charge_id → external_order_id map)" do
    let(:order_by_map) do
      tenant.orders.create!(
        channel: channel,
        external_id: "YAMPI-555099",
        order_number: "555099",
        ordered_at: Time.zone.parse("2026-06-20T10:00:00Z"),
        gross_value: 300.00,
        order_type: "sale"
      )
    end
    let(:map_page) do
      {
        data: [
          {
            id: "pay_map_linked",
            status: "paid",
            amount: 30000,
            fee: 900,
            anticipation_fee: 0,
            installment: 1,
            transaction_id: "tran_map_linked",
            charge_id: "ch_map_linked",
            recipient_id: "rp_1",
            payment_date: "2026-07-22",
            original_payment_date: "2026-07-22",
            payment_method: "pix",
            accrual_date: "2026-07-12T12:00:00Z",
            date_created: "2026-07-12T12:00:01Z"
          }
        ],
        paging: { forward_cursor: nil }
      }.to_json
    end
    let(:orders_with_charge) do
      {
        data: [
          {
            id: "or_map_linked",
            code: order_by_map.external_id,
            amount: 30000,
            status: "paid",
            created_at: "2026-06-20T10:00:00Z",
            charges: [
              {
                id: "ch_map_linked",
                code: order_by_map.external_id,
                amount: 30000,
                status: "paid",
                payment_method: "pix",
                paid_at: "2026-06-20T10:00:05Z",
                created_at: "2026-06-20T10:00:00Z"
              }
            ]
          }
        ],
        paging: { next: nil }
      }.to_json
    end

    before do
      # Único payable no período, sem nenhum FinancialSettlementItem legado
      # apontando pra order_by_map — os fallbacks antigos (payload
      # reference/charge_id/transaction_id) não têm como resolvê-lo sozinhos.
      stub_request(:get, payables_url)
        .with(query: { "payment_date_since" => "2026-07-01", "payment_date_until" => "2026-07-31", "recipient_id" => "rp_1", "size" => "1000" })
        .to_return(status: 200, body: map_page, headers: { "Content-Type" => "application/json" })
    end

    it "links the order via the /orders charge map when no legacy settlement item exists yet" do
      stub_request(:get, orders_url)
        .with(query: hash_including("created_since" => "2026-06-01", "created_until" => "2026-07-31"))
        .to_return(status: 200, body: orders_with_charge, headers: { "Content-Type" => "application/json" })

      described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")

      item = FinancialSettlementItem.find_by!(tenant: tenant, external_id: "pay_map_linked")
      expect(item.order).to eq(order_by_map)
    end

    it "falls back to no order (existing behavior) when the charge is absent from /orders" do
      stub_request(:get, orders_url)
        .with(query: hash_including("created_since" => "2026-06-01", "created_until" => "2026-07-31"))
        .to_return(status: 200, body: { data: [], paging: { next: nil } }.to_json, headers: { "Content-Type" => "application/json" })

      described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")

      item = FinancialSettlementItem.find_by!(tenant: tenant, external_id: "pay_map_linked")
      expect(item.order).to be_nil
    end
  end

  describe "fee-rate validation against PaymentFeeRule" do
    # Janela de data própria (agosto), separada da usada pelos stubs page_1/
    # page_2 no topo do arquivo (julho) — evita qualquer colisão de stub por
    # query params iguais. Sem order/charge_id no payload: o pedido não
    # precisa ser encontrado pra essa validação, e isso mantém as asserções
    # livres da reconciliação pedido x repasse (MatchSettlementItem), que é
    # um mecanismo independente (ver conflito de campos resolvido antes de
    # implementar esta feature).
    before do
      stub_request(:get, orders_url)
        .with(query: hash_including("created_since" => "2026-07-02", "created_until" => "2026-08-31"))
        .to_return(status: 200, body: { data: [], paging: { next: nil } }.to_json, headers: { "Content-Type" => "application/json" })
    end

    def stub_fee_payable(from:, to:, payable_id:, payment_method:, fee_cents:, amount_cents: 20000, card_brand: nil, installment: 1, anticipated: false)
      payment_date          = anticipated ? "2026-07-20" : "2026-07-21"
      original_payment_date = "2026-07-21"

      body = {
        data: [
          {
            id: payable_id,
            status: "paid",
            amount: amount_cents,
            fee: fee_cents,
            anticipation_fee: 0,
            installment: installment,
            transaction_id: "tran_#{payable_id}",
            recipient_id: "rp_1",
            payment_date: payment_date,
            original_payment_date: original_payment_date,
            payment_method: payment_method,
            card: (card_brand ? { brand: card_brand } : nil),
            accrual_date: "2026-07-10T12:00:00Z",
            date_created: "2026-07-10T12:00:01Z"
          }.compact
        ],
        paging: { forward_cursor: nil }
      }.to_json

      stub_request(:get, payables_url)
        .with(query: { "payment_date_since" => from, "payment_date_until" => to, "recipient_id" => "rp_1", "size" => "1000" })
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
    end

    def make_visa_rule(**overrides)
      tenant.payment_fee_rules.create!(
        {
          payment_method: "credit_card", card_brand: "visa", installments_from: 1, installments_to: 1,
          rate_type: "percentage", rate_value: 3.0, fixed_fee_gateway: 0.50, valid_from: Date.new(2026, 1, 1)
        }.merge(overrides)
      )
    end

    it "does not create a conflict when the charged fee matches the negotiated rate" do
      make_visa_rule
      stub_fee_payable(from: "2026-08-01", to: "2026-08-31", payable_id: "pay_fee_match", payment_method: "credit_card", card_brand: "visa", fee_cents: 650)

      result = described_class.call(financial_source, from: "2026-08-01", to: "2026-08-31")

      expect(result.success?).to eq(true)
      item = FinancialSettlementItem.find_by!(tenant: tenant, external_id: "pay_fee_match")
      expect(item.expected_fee_amount).to eq(BigDecimal("6.5"))
      expect(item.fee_difference_amount).to eq(BigDecimal("0.0"))
      expect(AuditConflict.where(tenant: tenant, conflict_type: "fee_rate_mismatch").count).to eq(0)
    end

    it "creates a fee_rate_mismatch conflict when the charged fee diverges from the negotiated rate" do
      make_visa_rule
      stub_fee_payable(from: "2026-08-01", to: "2026-08-31", payable_id: "pay_fee_diverge", payment_method: "credit_card", card_brand: "visa", fee_cents: 800)

      described_class.call(financial_source, from: "2026-08-01", to: "2026-08-31")

      item = FinancialSettlementItem.find_by!(tenant: tenant, external_id: "pay_fee_diverge")
      expect(item.expected_fee_amount).to eq(BigDecimal("6.5"))
      expect(item.fee_difference_amount).to eq(BigDecimal("1.5"))

      conflict = AuditConflict.find_by(tenant: tenant, conflict_type: "fee_rate_mismatch")
      expect(conflict).to be_present
      expect(conflict.status).to eq("open")
      expect(conflict.expected_value).to eq(BigDecimal("6.5"))
      expect(conflict.actual_value).to eq(BigDecimal("8.0"))
      expect(conflict.difference).to eq(BigDecimal("1.5"))
    end

    it "leaves expected_fee_amount nil and creates no conflict when there is no matching rule" do
      stub_fee_payable(from: "2026-08-01", to: "2026-08-31", payable_id: "pay_fee_no_rule", payment_method: "boleto", fee_cents: 300)

      described_class.call(financial_source, from: "2026-08-01", to: "2026-08-31")

      item = FinancialSettlementItem.find_by!(tenant: tenant, external_id: "pay_fee_no_rule")
      expect(item.expected_fee_amount).to be_nil
      expect(item.fee_difference_amount).to be_nil
      expect(AuditConflict.where(tenant: tenant, conflict_type: "fee_rate_mismatch").count).to eq(0)
    end

    it "ignores a rule whose valid_until has already passed" do
      make_visa_rule(valid_from: Date.new(2026, 1, 1), valid_until: Date.new(2026, 3, 31))
      stub_fee_payable(from: "2026-08-01", to: "2026-08-31", payable_id: "pay_fee_expired_rule", payment_method: "credit_card", card_brand: "visa", fee_cents: 800)

      described_class.call(financial_source, from: "2026-08-01", to: "2026-08-31")

      item = FinancialSettlementItem.find_by!(tenant: tenant, external_id: "pay_fee_expired_rule")
      expect(item.expected_fee_amount).to be_nil
      expect(item.fee_difference_amount).to be_nil
      expect(AuditConflict.where(tenant: tenant, conflict_type: "fee_rate_mismatch").count).to eq(0)
    end
  end
end
