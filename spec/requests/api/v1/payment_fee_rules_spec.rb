require "rails_helper"

RSpec.describe "Payment Fee Rules", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  let(:valid_params) do
    {
      payment_method: "credit_card",
      card_brand: "visa",
      installments_from: 1,
      installments_to: 1,
      rate_type: "percentage",
      rate_value: 3.5,
      valid_from: "2026-01-01"
    }
  end

  describe "GET /api/v1/payment_fee_rules" do
    it "lists the tenant's rules" do
      tenant.payment_fee_rules.create!(valid_params)

      get "/api/v1/payment_fee_rules", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.size).to eq(1)
      expect(body.first["payment_method"]).to eq("credit_card")
    end

    it "does not leak another tenant's rules" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      other_tenant.payment_fee_rules.create!(valid_params)

      get "/api/v1/payment_fee_rules", headers: auth_headers(operador)

      expect(JSON.parse(response.body)).to eq([])
    end
  end

  describe "POST /api/v1/payment_fee_rules" do
    it "requires admin" do
      post "/api/v1/payment_fee_rules", params: valid_params, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a rule for an admin" do
      post "/api/v1/payment_fee_rules", params: valid_params, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(tenant.payment_fee_rules.count).to eq(1)
    end

    it "rejects invalid params" do
      post "/api/v1/payment_fee_rules", params: valid_params.merge(card_brand: nil), headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to be_present
    end
  end

  describe "PUT /api/v1/payment_fee_rules/:id" do
    it "requires admin" do
      rule = tenant.payment_fee_rules.create!(valid_params)
      put "/api/v1/payment_fee_rules/#{rule.id}", params: { rate_value: 4.2 }, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "updates the rule" do
      rule = tenant.payment_fee_rules.create!(valid_params)

      put "/api/v1/payment_fee_rules/#{rule.id}", params: { rate_value: 4.2 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(rule.reload.rate_value).to eq(BigDecimal("4.2"))
    end
  end

  describe "DELETE /api/v1/payment_fee_rules/:id" do
    it "requires admin" do
      rule = tenant.payment_fee_rules.create!(valid_params)
      delete "/api/v1/payment_fee_rules/#{rule.id}", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "removes the rule" do
      rule = tenant.payment_fee_rules.create!(valid_params)

      delete "/api/v1/payment_fee_rules/#{rule.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(PaymentFeeRule.exists?(rule.id)).to eq(false)
    end
  end
end
