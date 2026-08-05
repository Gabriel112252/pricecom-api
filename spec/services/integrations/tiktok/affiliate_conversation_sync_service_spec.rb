require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateConversationSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Conversas", slug: "loja-conversas-#{SecureRandom.hex(4)}") }
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

  def message_entry(id:, sender_id:, content: "olá", create_time: 1_785_936_154, conversation_id: "conv-1")
    {
      "conversation_index" => "1785936154640500",
      "message_body" => {
        "id" => id,
        "conversation_id" => conversation_id,
        "type" => "TEXT",
        "content" => { content: content }.to_json,
        "create_time" => create_time,
        "sender_id" => sender_id
      }
    }
  end

  it "does nothing when the creator has no conversation_id yet" do
    creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC")
    allow(adapter).to receive(:fetch_conversation_messages)

    described_class.call(affiliate_creator: creator)

    expect(adapter).not_to have_received(:fetch_conversation_messages)
    expect(creator.affiliate_messages.count).to eq(0)
  end

  it "persists messages, parses the nested JSON content, and infers direction from sender_id" do
    creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
    allow(adapter).to receive(:fetch_conversation_messages)
      .with(conversation_id: "conv-1", page_token: nil)
      .and_return({
        "has_more" => false,
        "next_page_token" => "",
        "messages" => [
          message_entry(id: "m1", sender_id: "uABC", content: "resposta do criador"),
          message_entry(id: "m2", sender_id: "seller-sender-id", content: "mensagem da loja")
        ]
      })

    described_class.call(affiliate_creator: creator)

    inbound = creator.affiliate_messages.find_by(external_message_id: "m1")
    outbound = creator.affiliate_messages.find_by(external_message_id: "m2")
    expect(inbound.direction).to eq("inbound")
    expect(inbound.content).to eq("resposta do criador")
    expect(outbound.direction).to eq("outbound")
    expect(outbound.content).to eq("mensagem da loja")
    expect(outbound.sent_at).to eq(Time.zone.at(1_785_936_154))
  end

  it "does not insert a duplicate row when a message's external_message_id already exists for this creator" do
    creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
    creator.affiliate_messages.create!(
      external_message_id: "m1", direction: "outbound", content: "já salva", sent_at: Time.current
    )
    allow(adapter).to receive(:fetch_conversation_messages)
      .with(conversation_id: "conv-1", page_token: nil)
      .and_return({ "has_more" => false, "next_page_token" => "", "messages" => [ message_entry(id: "m1", sender_id: "uABC") ] })

    described_class.call(affiliate_creator: creator)

    expect(creator.affiliate_messages.where(external_message_id: "m1").count).to eq(1)
  end

  it "paginates while has_more is true, following next_page_token" do
    creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
    allow(adapter).to receive(:fetch_conversation_messages)
      .with(conversation_id: "conv-1", page_token: nil)
      .and_return({ "has_more" => true, "next_page_token" => "p2", "messages" => [ message_entry(id: "m1", sender_id: "uABC") ] })
    allow(adapter).to receive(:fetch_conversation_messages)
      .with(conversation_id: "conv-1", page_token: "p2")
      .and_return({ "has_more" => false, "next_page_token" => "", "messages" => [ message_entry(id: "m2", sender_id: "uABC") ] })

    described_class.call(affiliate_creator: creator)

    expect(creator.affiliate_messages.count).to eq(2)
  end

  it "skips entries with a blank message id instead of raising" do
    creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
    allow(adapter).to receive(:fetch_conversation_messages)
      .with(conversation_id: "conv-1", page_token: nil)
      .and_return({ "has_more" => false, "next_page_token" => "", "messages" => [ message_entry(id: "", sender_id: "uABC") ] })

    expect { described_class.call(affiliate_creator: creator) }.not_to raise_error
    expect(creator.affiliate_messages.count).to eq(0)
  end
end
