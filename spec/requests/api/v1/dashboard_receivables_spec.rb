require "rails_helper"

RSpec.describe "Dashboard receivables", type: :request do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:financial_source) do
    tenant.financial_sources.create!(provider: "pagarme", name: "Pagar.me", source_type: "gateway", status: "active")
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def make_receivable(payment_method:, charge_id:, payable_id: SecureRandom.hex(6), amount: 100, status: "paid")
    tenant.financial_receivables.create!(
      financial_source: financial_source,
      payable_id: payable_id,
      charge_id: charge_id,
      payment_method: payment_method,
      status: status,
      amount: amount,
      fee_amount: 0,
      anticipation_fee_amount: 0,
      net_amount: amount,
      payment_date: Date.current
    )
  end

  describe "GET /api/v1/dashboard/financial" do
    # This is the regression the payment-method gadget exists for: an
    # installment sale creates one financial_receivable row per parcela
    # (same charge_id), so counting rows makes credit_card look dominant
    # even when pix accounts for more actual sales.
    it "counts sales_by_payment_method by distinct charge_id, not by receivable row" do
      charge = SecureRandom.hex(6)
      3.times { |i| make_receivable(payment_method: "credit_card", charge_id: charge, payable_id: "#{charge}-#{i}") }
      2.times { make_receivable(payment_method: "pix", charge_id: SecureRandom.hex(6)) }

      get "/api/v1/dashboard/financial", headers: auth_headers(operador)

      dashboard = JSON.parse(response.body)["receivables_dashboard"]
      by_sale = dashboard["sales_by_payment_method"].index_by { |row| row["payment_method"] }
      by_row = dashboard["by_payment_method"].index_by { |row| row["payment_method"] }

      expect(by_sale["credit_card"]["sales_count"]).to eq(1)
      expect(by_sale["pix"]["sales_count"]).to eq(2)
      expect(by_row["credit_card"]["receivables_count"]).to eq(3)
      expect(by_row["pix"]["receivables_count"]).to eq(2)
    end

    it "computes share_pct across all payment methods in the filtered scope" do
      make_receivable(payment_method: "pix", charge_id: SecureRandom.hex(6))
      make_receivable(payment_method: "pix", charge_id: SecureRandom.hex(6))
      make_receivable(payment_method: "credit_card", charge_id: SecureRandom.hex(6))

      get "/api/v1/dashboard/financial", headers: auth_headers(operador)

      dashboard = JSON.parse(response.body)["receivables_dashboard"]
      by_sale = dashboard["sales_by_payment_method"].index_by { |row| row["payment_method"] }

      expect(by_sale["pix"]["share_pct"]).to eq(66.67)
      expect(by_sale["credit_card"]["share_pct"]).to eq(33.33)
    end

    it "excludes receivables without a charge_id from the sales count" do
      make_receivable(payment_method: "boleto", charge_id: nil)

      get "/api/v1/dashboard/financial", headers: auth_headers(operador)

      dashboard = JSON.parse(response.body)["receivables_dashboard"]
      expect(dashboard["sales_by_payment_method"]).to eq([])
    end
  end
end
