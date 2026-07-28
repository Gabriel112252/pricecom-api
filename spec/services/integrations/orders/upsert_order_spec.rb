require "rails_helper"

# Foco estreito: prova que os cinco campos UTM lidos por
# Integrations::Normalizers::YampiOrderNormalizer (spec dedicado) realmente
# chegam até a coluna do Order via UpsertOrder — o ponto de integração que
# um teste só do normalizer não cobre. order_has_utm_fields? é o mesmo
# padrão defensivo já usado para coupon_code/cart_token/shipping_service.
RSpec.describe Integrations::Orders::UpsertOrder do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:orders_fixture) { JSON.parse(File.read(Rails.root.join("spec/fixtures/integrations/yampi_orders.json"))) }
  let(:raw_order) { orders_fixture["data"].first }

  def upsert(raw_payload)
    channel
    normalized = Integrations::Normalizers::YampiOrderNormalizer.new(raw_payload, "").normalize
    described_class.call(tenant: tenant, normalized: normalized, provider: "yampi")
  end

  it "persists the five UTM fields read by the normalizer onto the order" do
    order_with_utm = raw_order.merge(
      "utm_source"   => "instagram",
      "utm_medium"   => "story",
      "utm_campaign" => "blackfriday2026",
      "utm_content"  => "banner1",
      "utm_term"     => "tenis-corrida"
    )

    result = upsert(order_with_utm)

    expect(result.success?).to eq(true)
    order = result.order
    expect(order.utm_source).to eq("instagram")
    expect(order.utm_medium).to eq("story")
    expect(order.utm_campaign).to eq("blackfriday2026")
    expect(order.utm_content).to eq("banner1")
    expect(order.utm_term).to eq("tenis-corrida")
  end

  it "leaves the UTM columns nil when the normalizer found none, matching every real sampled order today" do
    result = upsert(raw_order)

    order = result.order
    expect(order.utm_source).to be_nil
    expect(order.utm_medium).to be_nil
    expect(order.utm_campaign).to be_nil
    expect(order.utm_content).to be_nil
    expect(order.utm_term).to be_nil
  end

  it "updates the UTM fields on a re-sync of the same order (not just on first insert)" do
    upsert(raw_order)

    result = upsert(raw_order.merge("utm_source" => "google", "utm_medium" => "cpc"))

    order = result.order
    expect(order.utm_source).to eq("google")
    expect(order.utm_medium).to eq("cpc")
  end
end
