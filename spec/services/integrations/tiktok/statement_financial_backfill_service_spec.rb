require "rails_helper"

RSpec.describe Integrations::Tiktok::StatementFinancialBackfillService do
  let(:tenant) { Tenant.create!(name: "Loja Statement", slug: "statement-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }
  let(:lock) { instance_double(Integrations::Tiktok::FinancialSyncLock, acquire: true, release: true) }
  let(:statement) { { "id" => "statement-1", "statement_time" => 1_751_068_800, "payment_status" => "PAID" } }
  let(:transaction) do
    {
      "id" => "transaction-1",
      "type" => "ORDER",
      "order_id" => "order-1",
      "revenue_amount" => "100",
      "settlement_amount" => "80",
      "fee_tax_amount" => "20",
      "shipping_cost_amount" => "0",
      "fee_tax_breakdown" => {
        "fee" => {
          "platform_commission_amount" => "-10",
          "affiliate_commission_amount" => "-5",
          "fee_per_item_sold_amount" => "-2",
          "sfp_service_fee_amount" => "-3"
        }
      }
    }
  end

  before do
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
    allow(Integrations::Tiktok::FinancialSyncLock).to receive(:new).and_return(lock)
    allow(adapter).to receive(:fetch_financial_statements).and_return([ statement ])
    allow(adapter).to receive(:fetch_statement_transactions).and_return([ transaction ])
  end

  it "updates an existing order and does not create a missing order" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED")

    result = described_class.call(credential, date_from: "2026-07-01", date_to: "2026-07-01", run_id: "run-1")

    expect(result.success?).to eq(true)
    expect(order.reload.settlement_amount).to eq(BigDecimal("80"))
    expect(order.reload.financial_breakdown.dig("transactions", 0, "id")).to eq("transaction-1")
    expect(tenant.orders.where(external_id: "missing")).to be_empty
  end

  it "skips a successful statement on the second run without force" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED")

    described_class.call(credential, date_from: "2026-07-01", date_to: "2026-07-01", run_id: "run-1")
    described_class.call(credential, date_from: "2026-07-01", date_to: "2026-07-01", run_id: "run-2")

    expect(adapter).to have_received(:fetch_statement_transactions).once
    expect(order.reload.financial_synced_at).to be_present
  end

  it "reprocesses a statement explicitly with force" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED")

    described_class.call(credential, date_from: "2026-07-01", date_to: "2026-07-01", run_id: "run-1")
    described_class.call(credential, date_from: "2026-07-01", date_to: "2026-07-01", force: true, run_id: "run-2")

    expect(adapter).to have_received(:fetch_statement_transactions).twice
  end

  # Regressão: em produção, um statement TikTok PAID sem nenhuma transação
  # travava o backfill (job reagendando o mesmo statement a cada 2 minutos,
  # para sempre — ver StatementFinancialBackfillJob). A causa raiz era o
  # loop de paginação de transações por statement, que só encerrava quando
  # a API devolvia um next_page_token vazio; se a TikTok mandasse um token
  # não-nulo numa página já vazia (quirk real, visto em produção), o loop
  # nunca convergia e o statement nunca chegava em finish_statement_log.
  #
  # instance_double falha `is_a?(Integrations::TiktokAdapter)`, então os
  # testes acima (que usam esse double) exercitam só o branch legado de
  # #fetch_financial_statements/#fetch_statement_transactions — não o
  # caminho de checkpoint por página que roda de fato em produção. Esses
  # testes usam uma instância REAL do adapter (dublê parcial) para cobrir
  # o branch certo.
  describe "checkpoint pagination against the real adapter (production path)" do
    let(:real_adapter) { Integrations::TiktokAdapter.new(credential.credentials) }
    let(:empty_statement) { { "id" => "s-empty", "statement_time" => 1_749_024_000, "payment_status" => "PAID" } }

    before do
      allow(Integrations::TiktokAdapter).to receive(:new).and_return(real_adapter)
    end

    def statement_log_for(statement_id)
      tenant.integration_sync_logs.find_by(
        action: Integrations::Tiktok::StatementFinancialBackfillService::STATEMENT_ACTION,
        statement_id: statement_id
      )
    end

    it "marks a PAID statement with zero transactions as processed successfully, without looping" do
      allow(real_adapter).to receive(:fetch_financial_statements_page)
        .and_return({ "data" => { "statements" => [ empty_statement ], "next_page_token" => nil } })
      # next_page_token não-nulo numa página sem transação nenhuma —
      # reproduz o quirk real da API. Só pode ser chamado 1x: se o código
      # ainda tivesse o bug, essa expectativa falharia por "unexpected
      # message" em vez do teste travar num loop infinito de verdade.
      expect(real_adapter).to receive(:fetch_statement_transactions_page).once.and_return(
        { "data" => { "transactions" => [], "next_page_token" => "stale-token" } }
      )

      result = described_class.call(credential, date_from: "2026-06-04", date_to: "2026-06-04", run_id: "run-empty")

      expect(result.success?).to eq(true)
      log = statement_log_for("s-empty")
      expect(log.status).to eq("success")
      expect(log.processed_at).to be_present
      expect(log.transaction_count).to eq(0)
      expect(log.matched_order_count).to eq(0)
      expect(log.synced_order_count).to eq(0)
      expect(log.missing_order_count).to eq(0)
      expect(log.error_count).to eq(0)
    end

    it "advances to the next statement after an empty one instead of getting stuck on it" do
      next_statement = { "id" => "s-next", "statement_time" => 1_749_110_400, "payment_status" => "PAID" }
      order = tenant.orders.create!(channel: channel, external_id: "order-next", status: "COMPLETED")

      allow(real_adapter).to receive(:fetch_financial_statements_page)
        .and_return({ "data" => { "statements" => [ empty_statement, next_statement ], "next_page_token" => nil } })
      allow(real_adapter).to receive(:fetch_statement_transactions_page) do |args|
        if args[:statement_id] == "s-empty"
          { "data" => { "transactions" => [], "next_page_token" => nil } }
        else
          { "data" => { "transactions" => [ transaction.merge("order_id" => "order-next") ], "next_page_token" => nil } }
        end
      end

      result = described_class.call(credential, date_from: "2026-06-04", date_to: "2026-06-04", run_id: "run-advance")

      expect(result.success?).to eq(true)
      expect(statement_log_for("s-empty").status).to eq("success")
      expect(statement_log_for("s-next").status).to eq("success")
      expect(order.reload.financial_synced_at).to be_present
    end

    it "ignores an already-processed empty statement on re-run (idempotent, no re-fetch)" do
      allow(real_adapter).to receive(:fetch_financial_statements_page)
        .and_return({ "data" => { "statements" => [ empty_statement ], "next_page_token" => nil } })
      allow(real_adapter).to receive(:fetch_statement_transactions_page)
        .and_return({ "data" => { "transactions" => [], "next_page_token" => nil } })

      described_class.call(credential, date_from: "2026-06-04", date_to: "2026-06-04", run_id: "run-1")
      described_class.call(credential, date_from: "2026-06-04", date_to: "2026-06-04", run_id: "run-2")

      expect(real_adapter).to have_received(:fetch_statement_transactions_page).once
    end
  end
end
