require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateCampaignDispatchService do
  let(:tenant) { Tenant.create!(name: "Loja Campanha", slug: "loja-campanha-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let!(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end

  before { allow_any_instance_of(described_class).to receive(:sleep) }

  def create_creator(open_id, status: "NORMAL")
    channel.affiliate_creators.create!(tenant: tenant, creator_open_id: open_id, collaboration_status: status, conversation_id: "conv-#{open_id}")
  end

  it "materializes recipients from the segment_filter and sends to each one" do
    create_creator("u1")
    create_creator("u2")
    campaign = tenant.affiliate_campaigns.create!(
      channel: channel, name: "Campanha", message_template: "Oi!", segment_filter: { collaboration_status: "NORMAL" }
    )
    allow(Integrations::Tiktok::AffiliateMessageSendService).to receive(:call) do |affiliate_creator:, campaign_recipient:, **|
      campaign_recipient.update!(status: "sent", sent_at: Time.current)
    end

    result = described_class.call(campaign)

    expect(result.success?).to eq(true)
    expect(campaign.affiliate_campaign_recipients.count).to eq(2)
    expect(campaign.reload.status).to eq("completed")
    expect(campaign.sent_count).to eq(2)
  end

  it "does not duplicate recipients when the campaign is dispatched twice" do
    create_creator("u1")
    campaign = tenant.affiliate_campaigns.create!(channel: channel, name: "Campanha", message_template: "Oi", segment_filter: {})
    allow(Integrations::Tiktok::AffiliateMessageSendService).to receive(:call) do |campaign_recipient:, **|
      campaign_recipient.update!(status: "sent", sent_at: Time.current)
    end

    described_class.call(campaign)
    described_class.call(campaign)

    expect(campaign.affiliate_campaign_recipients.count).to eq(1)
  end

  it "stops the batch on a rate limit without marking the recipient as failed, and reports next_retry_at" do
    create_creator("u1")
    create_creator("u2")
    campaign = tenant.affiliate_campaigns.create!(channel: channel, name: "Campanha", message_template: "Oi", segment_filter: {})
    allow(Integrations::Tiktok::AffiliateMessageSendService).to receive(:call)
      .and_raise(Integrations::RateLimitError.new("rate limited", retry_after: 30))

    result = described_class.call(campaign)

    expect(result.next_retry_at).to be_present
    expect(campaign.affiliate_campaign_recipients.pluck(:status)).to all(eq("pending"))
    expect(campaign.reload.status).to eq("sending")
  end

  it "marks a recipient as failed on a non-rate-limit error and continues the batch" do
    create_creator("u1")
    create_creator("u2")
    campaign = tenant.affiliate_campaigns.create!(channel: channel, name: "Campanha", message_template: "Oi", segment_filter: {})
    allow(Integrations::Tiktok::AffiliateMessageSendService).to receive(:call)
      .and_raise(Integrations::ApiError, "algo deu errado")

    result = described_class.call(campaign)

    expect(result.next_retry_at).to be_nil
    expect(campaign.affiliate_campaign_recipients.pluck(:status)).to all(eq("failed"))
    expect(campaign.reload.failed_count).to eq(2)
  end
end
