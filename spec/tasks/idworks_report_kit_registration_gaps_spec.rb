require "rails_helper"
require "rake"

RSpec.describe "idworks:report_kit_registration_gaps rake task" do
  before(:all) do
    Rake::Task.define_task(:environment)
    unless Rake::Task.task_defined?("idworks:report_kit_registration_gaps")
      load Rails.root.join("lib/tasks/idworks_report_kit_registration_gaps.rake").to_s
    end
  end

  before { Rake::Task["idworks:report_kit_registration_gaps"].reenable }

  let(:tenant)  { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }

  around do |example|
    original = ENV.to_h.slice("DAYS", "TENANT_SLUG")
    example.run
    ENV["DAYS"] = original["DAYS"]
    ENV["TENANT_SLUG"] = original["TENANT_SLUG"]
  end

  def make_order
    tenant.orders.create!(channel: channel, external_id: SecureRandom.hex(4), order_number: SecureRandom.hex(4), order_type: "sale", gross_value: 100, ordered_at: 1.day.ago)
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  it "flags an is_kit:false product whose name suggests a kit as a registration gap" do
    kit044 = tenant.products.create!(sku: "KIT044", name: "HIDRABENE KIT CLAREADOR FACIAL", is_kit: false)
    make_order.order_items.create!(product: kit044, sku: kit044.sku, name: kit044.name, quantity: 17_110, unit_price: 10)

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["DAYS"] = "365"

    output = capture_stdout { Rake::Task["idworks:report_kit_registration_gaps"].invoke }

    expect(output).to match(/KIT044.*17110\.0 un\. no período.*is_kit=false/)
  end

  it "flags an is_kit:true product with no KitComponent rows as a registration gap" do
    empty_kit = tenant.products.create!(sku: "KIT099", name: "Kit Sem Componente", is_kit: true)
    make_order.order_items.create!(product: empty_kit, sku: empty_kit.sku, name: empty_kit.name, quantity: 10, unit_price: 10)

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["DAYS"] = "365"

    output = capture_stdout { Rake::Task["idworks:report_kit_registration_gaps"].invoke }

    expect(output).to match(/KIT099.*SEM KitComponent cadastrado/)
  end

  it "does not flag a correctly-registered kit (is_kit:true with components)" do
    leaf = tenant.products.create!(sku: "LEAF-1", name: "Componente")
    kit = tenant.products.create!(sku: "KIT-OK", name: "Kit OK", is_kit: true)
    kit.kit_components.create!(component_product: leaf, quantity: 1)
    make_order.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 5, unit_price: 10)

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["DAYS"] = "365"

    output = capture_stdout { Rake::Task["idworks:report_kit_registration_gaps"].invoke }

    expect(output).to match(/KIT-OK.*OK — is_kit=true, explode em 1 componente/)
  end

  it "flags two different SKUs sharing the exact same product name as a possible duplicate" do
    tenant.products.create!(sku: "KIT044", name: "HIDRABENE KIT CLAREADOR FACIAL", is_kit: false).tap do |p|
      make_order.order_items.create!(product: p, sku: p.sku, name: p.name, quantity: 17_110, unit_price: 10)
    end
    tenant.products.create!(sku: "2133823", name: "HIDRABENE KIT CLAREADOR FACIAL", is_kit: false).tap do |p|
      make_order.order_items.create!(product: p, sku: p.sku, name: p.name, quantity: 9_502, unit_price: 10)
    end

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["DAYS"] = "365"

    output = capture_stdout { Rake::Task["idworks:report_kit_registration_gaps"].invoke }

    expect(output).to match(/hidrabene kit clareador facial.*\n.*KIT044.*\n.*2133823/)
  end
end
