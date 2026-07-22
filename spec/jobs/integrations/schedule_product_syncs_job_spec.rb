require "rails_helper"

RSpec.describe Integrations::ScheduleProductSyncsJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }

  def create_credential(channel, status: "active", tenant: self.tenant)
    credentials = {
      "yampi" => { alias: "loja", token: "token", secret_key: "secret", webhook_secret: "webhook" },
      "shopify" => { shop_domain: "loja.myshopify.com", access_token: "token", webhook_secret: "webhook" },
      "tiktok" => { app_key: "app-key", app_secret: "app-secret" },
      "mercadolivre" => { user_id: "user", access_token: "token" },
      "shopee" => { shop_id: "shop", partner_id: "partner", partner_key: "key", access_token: "token" },
      "lucrofrete" => { email: "frete@example.com", password: "password" }
    }

    tenant.channel_credentials.create!(channel: channel, status: status, credentials: credentials.fetch(channel))
  end

  it "enqueues only active credentials for channels with registered adapters" do
    supported = Integrations::ProductSyncService::ADAPTERS.keys.map { |channel| create_credential(channel) }
    lucrofrete = create_credential("lucrofrete")
    inactive_tenant = Tenant.create!(name: "Loja Inativa", slug: "loja-#{SecureRandom.hex(4)}")
    inactive = create_credential("yampi", status: "error", tenant: inactive_tenant)
    enqueued_ids = []

    allow(Integrations::ProductSyncJob).to receive(:perform_later) { |id| enqueued_ids << id }

    described_class.new.perform

    expect(enqueued_ids).to contain_exactly(*supported.map(&:id))
    expect(enqueued_ids).not_to include(lucrofrete.id, inactive.id)
  end
end
