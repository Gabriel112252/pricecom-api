require "rails_helper"

# Regression coverage for a real bug: the normalizer was originally written
# against an assumed flat payload shape that doesn't match either of Yampi's
# actual real shapes (verified against docs.yampi.com.br/api-reference/
# pedidos and docs.yampi.com.br/api-reference/introduction-webhook on
# 2026-07-10):
#   - the Orders API returns the order directly, with `address` as an ARRAY
#     and totals under value_total/value_shipment/value_discount;
#   - webhook deliveries envelope the order under a top-level "resource" key,
#     with customer/status/shipping_address nested under "data".
# Before the fix, the first shape raised a TypeError (Hash#dig into an Array
# with a String key) and the second silently normalized to an all-blank order.
RSpec.describe Integrations::Normalizers::YampiOrderNormalizer do
  let(:orders_fixture) { JSON.parse(File.read(Rails.root.join("spec/fixtures/integrations/yampi_orders.json"))) }
  let(:raw_order) { orders_fixture["data"].first }

  describe "Orders API shape (address as an array, value_* totals)" do
    it "does not raise and extracts every field correctly" do
      normalized = described_class.new(raw_order, "").normalize

      expect(normalized).to include(
        external_id:   "1000001",
        order_number:  "555001",
        status:        "waiting_payment",
        customer_name: "Cliente Exemplo",
        state:         "SP",
        order_type:    "sale",
        gross_value:   199.90,
        freight:       19.90,
        discount:      0.0
      )
      expect(normalized[:ordered_at]).to eq(Time.zone.parse("2026-06-15 10:00:00"))
    end

    it "extracts item fields from the item_sku/price/price_cost/gift keys" do
      item = described_class.new(raw_order, "").normalize[:items].first

      expect(item).to include(
        sku:        "CAM-001-P-AZUL",
        name:       "Camiseta Premium P Azul",
        quantity:   2,
        unit_price: 90.0,
        unit_cost:  60.0,
        is_gift:    false
      )
    end

    it "classifies a cancelled order as order_type=cancellation from its status" do
      cancelled_order = orders_fixture["data"].second
      normalized = described_class.new(cancelled_order, "").normalize

      expect(normalized[:order_type]).to eq("cancellation")
    end
  end

  describe "promocode embedded via ?include=promocode" do
    it "reads coupon code and discount from the { data => {...} } envelope shape" do
      order = raw_order.merge(
        "promocode" => { "data" => { "code" => "BEMVINDO10", "discount" => 15.5 } }
      )

      normalized = described_class.new(order, "").normalize

      expect(normalized[:coupon_code]).to eq("BEMVINDO10")
      expect(normalized[:coupon_discount]).to eq(15.5)
    end

    it "still reads a flat promocode hash" do
      order = raw_order.merge("promocode" => { "code" => "FLAT5", "discount" => 5.0 })

      normalized = described_class.new(order, "").normalize

      expect(normalized[:coupon_code]).to eq("FLAT5")
      expect(normalized[:coupon_discount]).to eq(5.0)
    end
  end

  describe "webhook envelope shape (resource-wrapped, *.data nesting)" do
    let(:event_type) { "order.created" }
    let(:webhook_payload) do
      {
        "event" => event_type,
        "time" => "2026-06-15 10:00:00",
        "merchant" => { "id" => 123, "alias" => "loja-teste" },
        "resource" => raw_order.merge(
          "shipping_address" => { "data" => { "state" => "SP" } },
          "items" => { "data" => raw_order["items"] }
        ).except("address")
      }
    end
    let(:event) { instance_double("IntegrationEvent", payload: webhook_payload, event_type: event_type) }

    it "unwraps the resource envelope and extracts the same fields as the REST shape" do
      normalized = described_class.call(event)

      expect(normalized).to include(
        external_id:   "1000001",
        order_number:  "555001",
        status:        "waiting_payment",
        customer_name: "Cliente Exemplo",
        state:         "SP",
        gross_value:   199.90
      )
      expect(normalized[:items].first).to include(sku: "CAM-001-P-AZUL", unit_cost: 60.0)
    end

    it "does not mistake a bare (non-webhook) payload's lack of resource for an envelope" do
      bare_event = instance_double("IntegrationEvent", payload: raw_order, event_type: "")

      expect(described_class.call(bare_event)[:external_id]).to eq("1000001")
    end
  end
end
