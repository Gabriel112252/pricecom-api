require "rails_helper"
require "rake"

RSpec.describe "idworks:backfill_product_loja rake task" do
  before(:all) do
    Rake::Task.define_task(:environment)
    unless Rake::Task.task_defined?("idworks:backfill_product_loja")
      load Rails.root.join("lib/tasks/idworks_product_loja_backfill.rake").to_s
    end
  end

  before { Rake::Task["idworks:backfill_product_loja"].reenable }

  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:integration) { tenant.integrations.create!(provider: "idworks", name: "idworks", status: "connected", credentials: {}) }

  around do |example|
    original = ENV.to_h.slice("APPLY", "TENANT_SLUG")
    example.run
    ENV["APPLY"] = original["APPLY"]
    ENV["TENANT_SLUG"] = original["TENANT_SLUG"]
  end

  def invoke
    Rake::Task["idworks:backfill_product_loja"].invoke
  end

  it "in dry-run (default), counts but does not update products already matched by idworks (idworks_id present) and untagged" do
    integration
    already_tagged = tenant.products.create!(sku: "A", name: "A", idworks_id: "1", integration: integration)
    pre_backfill    = tenant.products.create!(sku: "B", name: "B", idworks_id: "2")
    never_synced    = tenant.products.create!(sku: "C", name: "C", idworks_id: nil)

    ENV.delete("APPLY")
    ENV["TENANT_SLUG"] = tenant.slug

    expect { invoke }.not_to change { [ already_tagged, pre_backfill, never_synced ].map { |p| p.reload.integration_id } }
  end

  it "with APPLY=1, tags only untagged products that have an idworks_id, leaving already-tagged and never-synced ones alone" do
    integration
    already_tagged = tenant.products.create!(sku: "A", name: "A", idworks_id: "1", integration: integration)
    pre_backfill    = tenant.products.create!(sku: "B", name: "B", idworks_id: "2")
    never_synced    = tenant.products.create!(sku: "C", name: "C", idworks_id: nil)

    ENV["APPLY"] = "1"
    ENV["TENANT_SLUG"] = tenant.slug

    invoke

    expect(pre_backfill.reload.integration_id).to eq(integration.id)
    expect(already_tagged.reload.integration_id).to eq(integration.id)
    expect(never_synced.reload.integration_id).to be_nil
  end

  it "skips a tenant that doesn't have exactly one idworks integration, without raising" do
    tenant.products.create!(sku: "B", name: "B", idworks_id: "2") # sem nenhuma integration idworks
    ENV["APPLY"] = "1"
    ENV["TENANT_SLUG"] = tenant.slug

    expect { invoke }.to output(/PULADO/).to_stdout
  end
end
