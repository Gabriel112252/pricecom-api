require "rails_helper"

# Assertions about the order/charge shape (id, code, amount-in-cents,
# status, paid_at, Basic Auth, page/size/created_since/created_until,
# paging.next) are verified against docs.pagar.me/reference on 2026-07-10.
# fee_amount/net_amount are NOT verified — the accessible Charge object
# docs show no fee field — see the class comment on PagarmeAdapter.
RSpec.describe Integrations::PagarmeAdapter do
  let(:credentials) { { api_key: "sk_test_abc123" } }
  let(:adapter) { described_class.new(credentials) }
  let(:orders_url) { "https://api.pagar.me/core/v5/orders" }
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/pagarme_orders.json")) }
  let(:expected_auth_header) { "Basic #{Base64.strict_encode64('sk_test_abc123:')}" }

  describe "#authenticate" do
    it "returns true when Pagar.me accepts the credentials via Basic Auth" do
      stub_request(:get, orders_url)
        .with(query: hash_including("page" => "1", "size" => "1"), headers: { "Authorization" => expected_auth_header })
        .to_return(status: 200, body: orders_fixture, headers: { "Content-Type" => "application/json" })

      expect(adapter.authenticate).to eq(true)
    end

    it "raises AuthenticationError on 401" do
      stub_request(:get, orders_url).with(query: hash_including("page" => "1"))
        .to_return(status: 401, body: { message: "Unauthorized" }.to_json)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises RateLimitError on 429" do
      stub_request(:get, orders_url).with(query: hash_including("page" => "1"))
        .to_return(status: 429, body: { message: "Too Many Requests" }.to_json, headers: { "Retry-After" => "10" })

      expect { adapter.authenticate }.to raise_error(Integrations::RateLimitError) do |error|
        expect(error.retry_after).to eq(10)
      end
    end
  end

  describe "#fetch_transactions" do
    before do
      stub_request(:get, orders_url)
        .with(query: hash_including("created_since" => "2026-06-01", "created_until" => "2026-06-30"))
        .to_return(status: 200, body: orders_fixture, headers: { "Content-Type" => "application/json" })
    end

    it "converts cents to reais and maps the order's code to external_order_id" do
      transactions = adapter.fetch_transactions(from: Date.new(2026, 6, 1), to: Date.new(2026, 6, 30))

      paid = transactions.find { |t| t[:external_id] == "ch_gmnW101c9YTvQVLB" }
      expect(paid).to include(
        external_order_id: "YAMPI-555001",
        gross_amount: 199.90,
        status: "paid"
      )
      expect(paid[:payment_date]).to eq(Time.zone.parse("2026-06-15T16:01:11Z"))
    end

    it "includes non-paid transactions too, with their real status" do
      transactions = adapter.fetch_transactions(from: Date.new(2026, 6, 1), to: Date.new(2026, 6, 30))

      failed = transactions.find { |t| t[:external_id] == "ch_nM5PkjcyLUa6Nr1w" }
      expect(failed).to include(status: "failed", gross_amount: 29.90)
    end

    it "stops paginating once paging.next is absent" do
      expect(WebMock).to have_not_requested(:get, orders_url).with(query: hash_including("page" => "2"))
      adapter.fetch_transactions(from: Date.new(2026, 6, 1), to: Date.new(2026, 6, 30))
      expect(WebMock).to have_not_requested(:get, orders_url).with(query: hash_including("page" => "2"))
    end
  end
end
