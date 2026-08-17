require "rails_helper"
require "rake"

RSpec.describe "idworks:shopify_cutoff_check rake task" do
  before(:all) do
    Rake::Task.define_task(:environment)
    unless Rake::Task.task_defined?("idworks:shopify_cutoff_check")
      load Rails.root.join("lib/tasks/idworks_shopify_cutoff_check.rake").to_s
    end
  end

  before { Rake::Task["idworks:shopify_cutoff_check"].reenable }

  let(:tenant)  { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }

  around do |example|
    original = ENV["TENANT_SLUG"]
    example.run
    ENV["TENANT_SLUG"] = original
  end

  def make_order(ordered_at:, idworks_sales_channel:)
    tenant.orders.create!(
      channel: channel, external_id: "o-#{SecureRandom.hex(4)}", order_number: SecureRandom.hex(4),
      order_type: "sale", gross_value: 100, ordered_at: ordered_at, idworks_sales_channel: idworks_sales_channel
    )
  end

  it "counts shopify orders before and from the cutoff separately, without mutating anything" do
    make_order(ordered_at: Date.new(2026, 6, 10), idworks_sales_channel: "shopify")
    make_order(ordered_at: Date.new(2026, 6, 14), idworks_sales_channel: "shopify")
    make_order(ordered_at: Date.new(2026, 6, 15), idworks_sales_channel: "shopify")
    make_order(ordered_at: Date.new(2026, 7, 1), idworks_sales_channel: "tiktok")

    ENV["TENANT_SLUG"] = tenant.slug

    output = capture_stdout { Rake::Task["idworks:shopify_cutoff_check"].invoke }

    expect(output).to match(/shopify antes.*2/)
    expect(output).to match(/shopify a partir.*1/)
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
