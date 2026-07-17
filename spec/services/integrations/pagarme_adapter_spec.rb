require "rails_helper"

RSpec.describe Integrations::PagarmeAdapter do
  let(:credentials) { { api_key: "sk_test_abc123" } }
  let(:adapter) { described_class.new(credentials) }
  let(:orders_url) { "https://api.pagar.me/core/v5/orders" }
  let(:payables_url) { "https://api.pagar.me/core/v5/payables" }
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/pagarme_orders.json")) }
  let(:expected_auth_header) { "Basic #{Base64.strict_encode64('sk_test_abc123:')}" }
  let(:payables_page_1) do
    {
      data: [
        {
          id: "pay_1",
          status: "waiting_funds",
          amount: 19990,
          fee: 1000,
          anticipation_fee: 550,
          installment: 1,
          transaction_id: "tran_1",
          charge_id: "ch_1",
          recipient_id: "rp_1",
          payment_date: "2026-07-20",
          original_payment_date: "2026-08-01",
          payment_method: "credit_card",
          accrual_at: "2026-07-10T12:00:00Z",
          created_at: "2026-07-10T12:00:01Z"
        }
      ],
      paging: { forward_cursor: "cursor_2" }
    }.to_json
  end
  let(:payables_page_2) do
    {
      data: [
        {
          id: "pay_2",
          status: "paid",
          amount: 5000,
          fee: 125,
          anticipation_fee: 0,
          installment: 1,
          transaction_id: "tran_2",
          payment_date: "2026-07-21",
          payment_method: "pix",
          accrual_at: "2026-07-11T12:00:00Z",
          created_at: "2026-07-11T12:00:01Z"
        }
      ],
      paging: { forward_cursor: nil }
    }.to_json
  end

  describe "#authenticate" do
    it "returns true when Pagar.me accepts the credentials via Basic Auth" do
      stub_request(:get, payables_url)
        .with(query: hash_including("size" => "1"), headers: { "Authorization" => expected_auth_header })
        .to_return(status: 200, body: { data: [], paging: { forward_cursor: nil } }.to_json, headers: { "Content-Type" => "application/json" })

      expect(adapter.authenticate).to eq(true)
    end

    it "raises AuthenticationError on 401" do
      stub_request(:get, payables_url).with(query: hash_including("size" => "1"))
        .to_return(status: 401, body: { message: "Unauthorized" }.to_json)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises RateLimitError on 429" do
      stub_request(:get, payables_url).with(query: hash_including("size" => "1"))
        .to_return(status: 429, body: { message: "Too Many Requests" }.to_json, headers: { "Retry-After" => "10" })

      expect { adapter.authenticate }.to raise_error(Integrations::RateLimitError) do |error|
        expect(error.retry_after).to eq(10)
      end
    end
  end

  describe "#fetch_payables" do
    before do
      stub_request(:get, payables_url)
        .with(query: { "payment_date_since" => "2026-07-01", "payment_date_until" => "2026-07-31", "size" => "1000" })
        .to_return(status: 200, body: payables_page_1, headers: { "Content-Type" => "application/json" })

      stub_request(:get, payables_url)
        .with(query: { "payment_date_since" => "2026-07-01", "payment_date_until" => "2026-07-31", "size" => "1000", "forward_cursor" => "cursor_2" })
        .to_return(status: 200, body: payables_page_2, headers: { "Content-Type" => "application/json" })
    end

    it "uses supported payment_date params, cursor pagination and maps payable fields" do
      payables = adapter.fetch_payables(payment_date_from: Date.new(2026, 7, 1), payment_date_to: Date.new(2026, 7, 31))

      expect(payables.size).to eq(2)
      expect(WebMock).to have_requested(:get, payables_url)
        .with(query: hash_including("payment_date_since" => "2026-07-01", "payment_date_until" => "2026-07-31"))
      expect(WebMock).to have_not_requested(:get, payables_url)
        .with(query: hash_including("payment_date[gte]" => "2026-07-01"))
      first = payables.first
      expect(first).to include(
        payable_id: "pay_1",
        status: "waiting_funds",
        amount: 199.90,
        fee_amount: 10.00,
        anticipation_fee_amount: 5.50,
        net_amount: 184.40,
        installment: 1,
        transaction_id: "tran_1",
        charge_id: "ch_1",
        recipient_id: "rp_1",
        payment_method: "credit_card",
        payment_date: Date.new(2026, 7, 20),
        original_payment_date: Date.new(2026, 8, 1)
      )
      expect(first[:accrual_date]).to eq(Time.zone.parse("2026-07-10T12:00:00Z"))
      expect(first[:date_created]).to eq(Time.zone.parse("2026-07-10T12:00:01Z"))
    end

    it "extracts originator_model and preserves the negative amount of a refund payable" do
      refund_body = {
        data: [
          {
            id: "pay_refund",
            status: "paid",
            amount: -10103,
            fee: 0,
            anticipation_fee: 0,
            installment: 1,
            transaction_id: "tran_refund",
            payment_method: "credit_card",
            originator_model: "refund",
            accrual_at: "2026-07-12T12:00:00Z",
            created_at: "2026-07-12T12:00:01Z"
          }
        ],
        paging: { forward_cursor: nil }
      }.to_json
      stub_request(:get, payables_url)
        .with(query: { "payment_date_since" => "2026-08-01", "payment_date_until" => "2026-08-31", "size" => "1000" })
        .to_return(status: 200, body: refund_body, headers: { "Content-Type" => "application/json" })

      payables = adapter.fetch_payables(payment_date_from: Date.new(2026, 8, 1), payment_date_to: Date.new(2026, 8, 31))

      refund = payables.first
      expect(refund[:originator_model]).to eq("refund")
      expect(refund[:amount]).to eq(-101.03)
      expect(refund[:net_amount]).to eq(-101.03)
    end

    it "can include status and recipient_id filters" do
      stub_request(:get, payables_url)
        .with(query: {
          "payment_date_since" => "2026-07-01",
          "payment_date_until" => "2026-07-31",
          "size" => "1000",
          "recipient_id" => "rp_1",
          "status" => "paid"
        })
        .to_return(status: 200, body: { data: [], paging: { forward_cursor: nil } }.to_json, headers: { "Content-Type" => "application/json" })

      adapter.fetch_payables(
        payment_date_from: Date.new(2026, 7, 1),
        payment_date_to: Date.new(2026, 7, 31),
        recipient_id: "rp_1",
        status: "paid"
      )

      expect(WebMock).to have_requested(:get, payables_url)
        .with(query: hash_including("recipient_id" => "rp_1", "status" => "paid"))
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
