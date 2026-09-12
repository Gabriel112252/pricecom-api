require "rails_helper"

RSpec.describe Integrations::IdworksAdapter do
  it "captures TypeOrder from the real IDWorks orders payload" do
    adapter = described_class.new({})

    order = adapter.send(:normalize_order, {
      "IDOrder" => 21_347_399,
      "Order" => "DV21347399",
      "TypeOrder" => "Devolução",
      "StatusOrder" => "Nota Fiscal",
      "ValueOrder" => "25469.89"
    })

    expect(order[:type_order]).to eq("Devolução")
  end
end
