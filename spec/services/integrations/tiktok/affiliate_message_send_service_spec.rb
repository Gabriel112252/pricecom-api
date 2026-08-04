require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateMessageSendService do
  let(:tenant) { Tenant.create!(name: "Loja Msg", slug: "loja-msg-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let!(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }

  before { allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter) }

  it "creates a conversation first when the creator has none yet, then sends the message" do
    creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC")
    allow(adapter).to receive(:create_conversation).with(creator_open_id: "uABC")
      .and_return({ "conversation_id" => "conv-1" })
    allow(adapter).to receive(:send_message).with(conversation_id: "conv-1", content: "Olá!")
      .and_return({ "message_id" => "msg-1" })

    message = described_class.call(affiliate_creator: creator, content: "Olá!")

    expect(creator.reload.conversation_id).to eq("conv-1")
    expect(message.content).to eq("Olá!")
    expect(message.direction).to eq("outbound")
  end

  it "reuses an existing conversation_id instead of creating a new one" do
    creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-9")
    allow(adapter).to receive(:send_message).and_return({})

    described_class.call(affiliate_creator: creator, content: "Oi de novo")

    expect(adapter).to have_received(:send_message).with(conversation_id: "conv-9", content: "Oi de novo")
  end

  it "marks the campaign recipient as sent and links the message" do
    creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-9")
    allow(adapter).to receive(:send_message).and_return({})
    campaign = tenant.affiliate_campaigns.create!(channel: channel, name: "Campanha 1")
    recipient = campaign.affiliate_campaign_recipients.create!(affiliate_creator: creator)

    message = described_class.call(affiliate_creator: creator, content: "Oi", campaign_recipient: recipient)

    expect(recipient.reload.status).to eq("sent")
    expect(recipient.affiliate_message).to eq(message)
    expect(recipient.sent_at).to be_present
  end

  it "propagates RateLimitError instead of swallowing it, so the caller decides how to handle it" do
    creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-9")
    allow(adapter).to receive(:send_message).and_raise(Integrations::RateLimitError.new("rate limited", retry_after: 10))

    expect { described_class.call(affiliate_creator: creator, content: "Oi") }
      .to raise_error(Integrations::RateLimitError)
  end
end
