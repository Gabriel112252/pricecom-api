require "rails_helper"
require "rake"

RSpec.describe "idworks:diagnose_channel_breakdown rake task" do
  before(:all) do
    Rake::Task.define_task(:environment)
    unless Rake::Task.task_defined?("idworks:diagnose_channel_breakdown")
      load Rails.root.join("lib/tasks/idworks_channel_diagnosis.rake").to_s
    end
  end

  before { Rake::Task["idworks:diagnose_channel_breakdown"].reenable }

  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }

  around do |example|
    original = ENV.to_h.slice("DAYS", "TENANT_SLUG")
    example.run
    ENV["DAYS"] = original["DAYS"]
    ENV["TENANT_SLUG"] = original["TENANT_SLUG"]
  end

  it "reports raw and scoped order counts per channel, without mutating anything" do
    shopee = tenant.channels.create!(name: "Shopee", platform: "shopee")
    tenant.orders.create!(
      channel: shopee, external_id: "1", order_number: "1", order_type: "sale",
      gross_value: 100, ordered_at: 1.day.ago
    )

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["DAYS"] = "30"

    expect { Rake::Task["idworks:diagnose_channel_breakdown"].invoke }
      .to output(/shopee \(Shopee\): 1 pedido\(s\) no período bruto, 1 após/).to_stdout
  end
end
