require "rails_helper"

RSpec.describe Integrations::Shopee::TokenRefreshJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }

  def create_credential(extra = {})
    tenant.channel_credentials.create!(
      channel: "shopee",
      status: "active",
      credentials: {
        "partner_id" => "2011234",
        "partner_key" => "partner-secret",
        "shop_id" => "9001",
        "access_token" => "old-access",
        "refresh_token" => "old-refresh"
      }.merge(extra)
    )
  end

  it "refreshes when token_expires_at is inside the leeway window and ensures the Channel" do
    credential = create_credential("token_expires_at" => 1.hour.from_now.iso8601)
    allow(Integrations::ShopeeAuthService).to receive(:refresh_credential!)

    described_class.new.perform(credential.id)

    expect(Integrations::ShopeeAuthService).to have_received(:refresh_credential!).with(credential)
    expect(tenant.channels.find_by(platform: "shopee")).to be_present
  end

  it "refreshes when token_expires_at is missing" do
    credential = create_credential
    allow(Integrations::ShopeeAuthService).to receive(:refresh_credential!)

    described_class.new.perform(credential.id)

    expect(Integrations::ShopeeAuthService).to have_received(:refresh_credential!).with(credential)
  end

  it "skips when the token still outlives the leeway (fresh OAuth)" do
    credential = create_credential("token_expires_at" => 4.hours.from_now.iso8601)
    allow(Integrations::ShopeeAuthService).to receive(:refresh_credential!)

    described_class.new.perform(credential.id)

    expect(Integrations::ShopeeAuthService).not_to have_received(:refresh_credential!)
  end

  it "skips silently when the credential never went through OAuth" do
    credential = tenant.channel_credentials.create!(
      channel: "shopee",
      status: "active",
      credentials: { "partner_id" => "2011234", "partner_key" => "partner-secret" }
    )
    allow(Integrations::ShopeeAuthService).to receive(:refresh_credential!)

    described_class.new.perform(credential.id)

    expect(Integrations::ShopeeAuthService).not_to have_received(:refresh_credential!)
  end

  it "marks the credential as error when the refresh_token is rejected" do
    credential = create_credential("token_expires_at" => 1.hour.from_now.iso8601)
    allow(Integrations::ShopeeAuthService).to receive(:refresh_credential!)
      .and_raise(Integrations::AuthenticationError, "refresh token expirado")

    described_class.new.perform(credential.id)

    expect(credential.reload.status).to eq("error")
  end

  it "re-enqueues itself respecting retry_after on rate limit" do
    credential = create_credential("token_expires_at" => 1.hour.from_now.iso8601)
    allow(Integrations::ShopeeAuthService).to receive(:refresh_credential!)
      .and_raise(Integrations::RateLimitError.new("limite", retry_after: 120))
    delayed = class_double(described_class, perform_later: nil)
    allow(described_class).to receive(:set).and_return(delayed)

    described_class.new.perform(credential.id)

    expect(described_class).to have_received(:set).with(wait: 120.seconds)
    expect(delayed).to have_received(:perform_later).with(credential.id)
  end
end

RSpec.describe Integrations::Shopee::TokenRefreshSchedulerJob do
  # channel é único por tenant — cada credential do spec vive em um tenant
  # próprio, como em produção (multi-tenant, uma loja Shopee por tenant).
  def create_credential(status: "active", credentials: nil)
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}")
    tenant.channel_credentials.create!(
      channel: "shopee",
      status: status,
      credentials: credentials || {
        "partner_id" => "2011234",
        "partner_key" => "partner-secret",
        "shop_id" => "9001",
        "access_token" => "token",
        "refresh_token" => "refresh"
      }
    )
  end

  it "enqueues one TokenRefreshJob per active Shopee credential with a refresh_token" do
    authorized = create_credential
    enqueued_ids = []
    allow(Integrations::Shopee::TokenRefreshJob).to receive(:perform_later) { |id| enqueued_ids << id }

    described_class.new.perform

    expect(enqueued_ids).to eq([ authorized.id ])
  end

  it "skips credentials in error and credentials that never authorized" do
    create_credential(status: "error")
    create_credential(
      status: "active",
      credentials: { "partner_id" => "2011234", "partner_key" => "partner-secret" }
    ) # sem refresh_token: connect feito, OAuth pendente
    allow(Integrations::Shopee::TokenRefreshJob).to receive(:perform_later)

    described_class.new.perform

    expect(Integrations::Shopee::TokenRefreshJob).not_to have_received(:perform_later)
  end
end
