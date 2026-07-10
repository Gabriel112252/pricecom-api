require "rails_helper"

RSpec.describe ChannelCredential, type: :model do
  it "encrypts credentials at rest and decrypts on read" do
    tenant = Tenant.create!(name: "Test Tenant", slug: "test-tenant-#{SecureRandom.hex(4)}")
    credential = tenant.channel_credentials.create!(
      channel: "shopify",
      credentials: { shop_domain: "test.myshopify.com", access_token: "shpat_abc", webhook_secret: "wh_secret" }
    )

    raw = ActiveRecord::Base.connection.select_value(
      "SELECT credentials::text FROM channel_credentials WHERE id = #{credential.id}"
    )
    expect(raw).not_to include("shpat_abc")

    credential.reload
    expect(credential.credentials["access_token"]).to eq("shpat_abc")
  end
end
