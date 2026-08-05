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

  it "persists messages and parses the nested JSON content" do
    creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
    allow(adapter).to receive(:fetch_conversation_messages)
      .with(conversation_id: "conv-1", page_token: nil)
      .and_return({
        "has_more" => false,
        "next_page_token" => "",
        "messages" => [ message_entry(id: "m1", sender_id: "3973499086299425538", content: "resposta do criador") ]
      })

    described_class.call(affiliate_creator: creator)

    message = creator.affiliate_messages.find_by(external_message_id: "m1")
    expect(message.content).to eq("resposta do criador")
    expect(message.sent_at).to eq(Time.zone.at(1_785_936_154))
  end

  describe "#infer_direction" do
    # BUG FIXED 2026-08-06: sender_id (TikTok's internal IM namespace) was
    # being compared against AffiliateCreator#creator_open_id (the
    # Affiliate/Collaboration namespace) — the two never match in practice,
    # so every synced message used to fall through to "outbound", including
    # real creator replies. The real signal is the shop's own IM
    # sender_id, a per-shop constant learned into
    # ChannelCredential#tiktok_seller_im_sender_id (see the "learns..."
    # examples below) — see also TiktokAdapter's class comment.
    it "marks a message as outbound when sender_id matches the shop's learned tiktok_seller_im_sender_id" do
      credential.update!(tiktok_seller_im_sender_id: "7497814839709541074")
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
      allow(adapter).to receive(:fetch_conversation_messages)
        .with(conversation_id: "conv-1", page_token: nil)
        .and_return({
          "has_more" => false, "next_page_token" => "",
          "messages" => [ message_entry(id: "m1", sender_id: "7497814839709541074") ]
        })

      described_class.call(affiliate_creator: creator)

      expect(creator.affiliate_messages.find_by(external_message_id: "m1").direction).to eq("outbound")
    end

    it "marks a message as inbound when sender_id is an unrecognized creator id, even though it's not creator_open_id" do
      credential.update!(tiktok_seller_im_sender_id: "7497814839709541074")
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
      allow(adapter).to receive(:fetch_conversation_messages)
        .with(conversation_id: "conv-1", page_token: nil)
        .and_return({
          "has_more" => false, "next_page_token" => "",
          "messages" => [ message_entry(id: "m1", sender_id: "3973499086299425538") ]
        })

      described_class.call(affiliate_creator: creator)

      expect(creator.affiliate_messages.find_by(external_message_id: "m1").direction).to eq("inbound")
    end

    it "defaults to inbound (the conservative choice), not outbound, when tiktok_seller_im_sender_id hasn't been learned yet" do
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
      allow(adapter).to receive(:fetch_conversation_messages)
        .with(conversation_id: "conv-1", page_token: nil)
        .and_return({
          "has_more" => false, "next_page_token" => "",
          "messages" => [ message_entry(id: "m1", sender_id: "3973499086299425538") ]
        })

      described_class.call(affiliate_creator: creator)

      expect(creator.affiliate_messages.find_by(external_message_id: "m1").direction).to eq("inbound")
    end

    it "still treats a sender_id == creator_open_id match as outbound (kept as a harmless fallback)" do
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
      allow(adapter).to receive(:fetch_conversation_messages)
        .with(conversation_id: "conv-1", page_token: nil)
        .and_return({
          "has_more" => false, "next_page_token" => "",
          "messages" => [ message_entry(id: "m1", sender_id: "uABC") ]
        })

      described_class.call(affiliate_creator: creator)

      expect(creator.affiliate_messages.find_by(external_message_id: "m1").direction).to eq("outbound")
    end

    it "learns tiktok_seller_im_sender_id from a message we know for certain is ours (blank raw_payload = created by AffiliateMessageSendService)" do
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
      creator.affiliate_messages.create!(
        external_message_id: "m1", direction: "outbound", content: "oi", sent_at: Time.current
      )
      allow(adapter).to receive(:fetch_conversation_messages)
        .with(conversation_id: "conv-1", page_token: nil)
        .and_return({
          "has_more" => false, "next_page_token" => "",
          "messages" => [ message_entry(id: "m1", sender_id: "7497814839709541074") ]
        })

      described_class.call(affiliate_creator: creator)

      expect(credential.reload.tiktok_seller_im_sender_id).to eq("7497814839709541074")
    end

    it "never overwrites an already-learned tiktok_seller_im_sender_id" do
      credential.update!(tiktok_seller_im_sender_id: "already-confirmed-id")
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
      creator.affiliate_messages.create!(
        external_message_id: "m1", direction: "outbound", content: "oi", sent_at: Time.current
      )
      allow(adapter).to receive(:fetch_conversation_messages)
        .with(conversation_id: "conv-1", page_token: nil)
        .and_return({
          "has_more" => false, "next_page_token" => "",
          "messages" => [ message_entry(id: "m1", sender_id: "some-other-id") ]
        })

      described_class.call(affiliate_creator: creator)

      expect(credential.reload.tiktok_seller_im_sender_id).to eq("already-confirmed-id")
    end

    it "does NOT learn from a pre-existing row that has a raw_payload (a previously synced row isn't a confirmed 'ours', even if it's tagged outbound)" do
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC", conversation_id: "conv-1")
      creator.affiliate_messages.create!(
        external_message_id: "m1", direction: "outbound", content: "oi", sent_at: Time.current,
        raw_payload: { "message_body" => { "sender_id" => "some-creator-id" } }
      )
      allow(adapter).to receive(:fetch_conversation_messages)
        .with(conversation_id: "conv-1", page_token: nil)
        .and_return({
          "has_more" => false, "next_page_token" => "",
          "messages" => [ message_entry(id: "m1", sender_id: "some-creator-id") ]
        })

      described_class.call(affiliate_creator: creator)

      expect(credential.reload.tiktok_seller_im_sender_id).to be_nil
    end
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
