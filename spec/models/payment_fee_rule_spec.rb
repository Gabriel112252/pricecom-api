require "rails_helper"

RSpec.describe PaymentFeeRule do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }

  def make_rule(**overrides)
    tenant.payment_fee_rules.create!(
      {
        payment_method: "credit_card",
        card_brand: "visa",
        installments_from: 1,
        installments_to: 1,
        rate_type: "percentage",
        rate_value: 3.5,
        valid_from: Date.new(2026, 1, 1)
      }.merge(overrides)
    )
  end

  describe "validations" do
    it "requires card_brand for credit_card" do
      rule = tenant.payment_fee_rules.new(
        payment_method: "credit_card", card_brand: nil, installments_from: 1, installments_to: 1,
        rate_type: "percentage", rate_value: 3.5, valid_from: Date.current
      )

      expect(rule).not_to be_valid
      expect(rule.errors[:card_brand]).to be_present
    end

    it "rejects card_brand for pix" do
      rule = tenant.payment_fee_rules.new(
        payment_method: "pix", card_brand: "visa", installments_from: 1, installments_to: 1,
        rate_type: "percentage", rate_value: 1.0, valid_from: Date.current
      )

      expect(rule).not_to be_valid
      expect(rule.errors[:card_brand]).to be_present
    end

    it "rejects installments_to below installments_from" do
      rule = tenant.payment_fee_rules.new(
        payment_method: "credit_card", card_brand: "visa", installments_from: 6, installments_to: 2,
        rate_type: "percentage", rate_value: 3.5, valid_from: Date.current
      )

      expect(rule).not_to be_valid
      expect(rule.errors[:installments_to]).to be_present
    end
  end

  describe ".find_for" do
    it "finds a rule matching payment_method, card_brand and installment range" do
      rule = make_rule(installments_from: 2, installments_to: 6, valid_until: nil)

      found = described_class.find_for(
        tenant: tenant, payment_method: "credit_card", card_brand: "visa", installment: 4, date: Date.new(2026, 6, 1)
      )

      expect(found).to eq(rule)
    end

    it "returns nil when installment falls outside the range" do
      make_rule(installments_from: 2, installments_to: 6, valid_until: nil)

      found = described_class.find_for(
        tenant: tenant, payment_method: "credit_card", card_brand: "visa", installment: 1, date: Date.new(2026, 6, 1)
      )

      expect(found).to be_nil
    end

    it "returns nil when the rule has expired (valid_until in the past)" do
      make_rule(valid_from: Date.new(2026, 1, 1), valid_until: Date.new(2026, 3, 31))

      found = described_class.find_for(
        tenant: tenant, payment_method: "credit_card", card_brand: "visa", installment: 1, date: Date.new(2026, 6, 1)
      )

      expect(found).to be_nil
    end

    it "matches an open-ended rule (valid_until nil) regardless of how far in the future the date is" do
      rule = make_rule(valid_from: Date.new(2026, 1, 1), valid_until: nil)

      found = described_class.find_for(
        tenant: tenant, payment_method: "credit_card", card_brand: "visa", installment: 1, date: Date.new(2030, 1, 1)
      )

      expect(found).to eq(rule)
    end

    it "does not match a rule for a different card brand" do
      make_rule(card_brand: "visa")

      found = described_class.find_for(
        tenant: tenant, payment_method: "credit_card", card_brand: "mastercard", installment: 1, date: Date.new(2026, 6, 1)
      )

      expect(found).to be_nil
    end

    it "matches pix/boleto rules with card_brand nil" do
      rule = make_rule(payment_method: "pix", card_brand: nil, installments_from: 1, installments_to: 1, rate_value: 0.99)

      found = described_class.find_for(
        tenant: tenant, payment_method: "pix", card_brand: nil, installment: 1, date: Date.new(2026, 6, 1)
      )

      expect(found).to eq(rule)
    end

    it "prefers the most recently started rule when more than one matches" do
      make_rule(valid_from: Date.new(2026, 1, 1), rate_value: 3.5)
      newer = make_rule(valid_from: Date.new(2026, 4, 1), rate_value: 2.9)

      found = described_class.find_for(
        tenant: tenant, payment_method: "credit_card", card_brand: "visa", installment: 1, date: Date.new(2026, 6, 1)
      )

      expect(found).to eq(newer)
    end
  end
end
