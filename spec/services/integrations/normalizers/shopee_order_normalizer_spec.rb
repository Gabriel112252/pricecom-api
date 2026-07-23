require "rails_helper"

RSpec.describe Integrations::Normalizers::ShopeeOrderNormalizer do
  def build_payload(overrides = {})
    {
      "order_sn" => "2207215TXAB123",
      "order_status" => "READY_TO_SHIP",
      "create_time" => 1_752_000_000,
      "update_time" => 1_752_010_000,
      "total_amount" => 95.0,
      "payment_method" => "Pix",
      "buyer_username" => "cliente1",
      "region" => "BR",
      "estimated_shipping_fee" => 15.0,
      "actual_shipping_fee" => 12.0,
      "recipient_address" => { "name" => "Maria Silva", "state" => "SP" },
      "item_list" => [
        {
          "item_id" => 111,
          "item_name" => "Sérum Facial",
          "item_sku" => "PAI-1",
          "model_id" => 999,
          "model_name" => "30ml",
          "model_sku" => "SKU-30ML",
          "model_quantity_purchased" => 2,
          "model_original_price" => 50.0,
          "model_discounted_price" => 40.0
        }
      ]
    }.merge(overrides)
  end

  def normalize(overrides = {})
    described_class.new(build_payload(overrides), "order.polling").normalize
  end

  it "computes gross_value as pre-discount products + freight, never total_amount" do
    normalized = normalize

    # 2 × 50.00 (original) + 15.00 de frete — total_amount (95.0, pós-
    # desconto) não pode aparecer aqui: foi o bug dos 29k pedidos TikTok.
    expect(normalized[:gross_value]).to eq(115.0)
    expect(normalized[:gross_value]).not_to eq(95.0)
  end

  it "computes discount from the original vs discounted delta and prices items post-discount" do
    normalized = normalize

    expect(normalized[:discount]).to eq(20.0)
    expect(normalized[:platform_discount]).to eq(0.0)

    item = normalized[:items].first
    expect(item[:sku]).to eq("SKU-30ML")
    expect(item[:quantity]).to eq(2)
    expect(item[:unit_price]).to eq(40.0)
    expect(item[:discount]).to eq(20.0)
    expect(item[:name]).to eq("Sérum Facial (30ml)")
    expect(item[:external_product_id]).to eq("111")
  end

  it "uses estimated_shipping_fee (buyer side) as freight, not actual_shipping_fee (seller logistics cost)" do
    normalized = normalize

    expect(normalized[:freight]).to eq(15.0)
  end

  it "keeps order_sn as external_id and order_number" do
    normalized = normalize

    expect(normalized[:external_id]).to eq("2207215TXAB123")
    expect(normalized[:order_number]).to eq("2207215TXAB123")
  end

  it "maps UNPAID to the canonical non-revenue spelling" do
    normalized = normalize("order_status" => "UNPAID")

    expect(normalized[:status]).to eq("unpaid")
  end

  it "marks CANCELLED as cancellation but keeps IN_CANCEL (request only) as sale" do
    expect(normalize("order_status" => "CANCELLED")[:order_type]).to eq("cancellation")
    expect(normalize("order_status" => "IN_CANCEL")[:order_type]).to eq("sale")
    expect(normalize("order_status" => "TO_RETURN")[:order_type]).to eq("refund")
  end

  it "extracts customer and state from recipient_address with buyer/region fallbacks" do
    normalized = normalize

    expect(normalized[:customer_name]).to eq("Maria Silva")
    expect(normalized[:state]).to eq("SP")

    without_address = normalize("recipient_address" => nil)
    expect(without_address[:customer_name]).to eq("cliente1")
    expect(without_address[:state]).to eq("BR")
  end

  it "parses ordered_at from the unix create_time" do
    expect(normalize[:ordered_at]).to eq(Time.zone.at(1_752_000_000))
  end

  it "falls back to paid total + discount when item_list is missing" do
    normalized = normalize("item_list" => nil)

    expect(normalized[:items]).to eq([])
    expect(normalized[:gross_value]).to eq(95.0)
  end

  it "sums multi-item orders and skips negative price deltas" do
    normalized = normalize(
      "item_list" => [
        {
          "item_id" => 1, "item_name" => "A", "model_sku" => "A1",
          "model_quantity_purchased" => 1, "model_original_price" => 100.0, "model_discounted_price" => 90.0
        },
        {
          "item_id" => 2, "item_name" => "B", "model_sku" => "B1",
          "model_quantity_purchased" => 3, "model_original_price" => 10.0, "model_discounted_price" => 10.0
        }
      ]
    )

    expect(normalized[:gross_value]).to eq(100.0 + 30.0 + 15.0)
    expect(normalized[:discount]).to eq(10.0)
  end
end
