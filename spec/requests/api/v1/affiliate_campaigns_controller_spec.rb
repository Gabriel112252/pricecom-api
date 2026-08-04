require "rails_helper"

RSpec.describe "Affiliate campaigns", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:channel)  { Channel.ensure_for!(tenant, "tiktok") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "POST /api/v1/affiliate_campaigns" do
    it "creates the campaign as draft and enqueues the dispatch job, without sending anything inline" do
      channel
      allow(Integrations::Tiktok::AffiliateCampaignDispatchJob).to receive(:perform_later)

      post "/api/v1/affiliate_campaigns",
        params: { name: "Reengajar top GMV", message_template: "Oi, tudo bem?", segment_filter: { collaboration_status: "NORMAL" } },
        headers: auth_headers(operador)

      expect(response).to have_http_status(:created)
      campaign = tenant.affiliate_campaigns.last
      expect(campaign.status).to eq("draft")
      expect(Integrations::Tiktok::AffiliateCampaignDispatchJob).to have_received(:perform_later).with(campaign.id)
    end

    it "returns an error when there is no tiktok channel yet" do
      post "/api/v1/affiliate_campaigns", params: { name: "Campanha" }, headers: auth_headers(operador)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /api/v1/affiliate_campaigns" do
    it "returns not_viewed_estimate as nil with unread_check_failed when there is no active credential" do
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u1", conversation_id: "conv-1")
      campaign = tenant.affiliate_campaigns.create!(channel: channel, name: "Campanha")
      campaign.affiliate_campaign_recipients.create!(affiliate_creator: creator, status: "sent", sent_at: Time.current)

      get "/api/v1/affiliate_campaigns", headers: auth_headers(operador)

      row = JSON.parse(response.body)["rows"].first
      expect(row["not_viewed_estimate"]).to be_nil
      expect(row["unread_check_failed"]).to eq(true)
    end
  end
end
