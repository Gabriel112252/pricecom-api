require "rails_helper"
require "rake"

RSpec.describe "tiktok:affiliate_messages rake tasks" do
  before(:all) do
    Rake::Task.define_task(:environment)
    unless Rake::Task.task_defined?("tiktok:affiliate_messages:dedupe")
      load Rails.root.join("lib/tasks/tiktok_affiliate_messages.rake").to_s
    end
  end

  before do
    Rake::Task["tiktok:affiliate_messages:dedupe"].reenable
    Rake::Task["tiktok:affiliate_messages:fix_directions"].reenable
  end

  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:creator) { channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "uABC") }
  let(:campaign) { tenant.affiliate_campaigns.create!(channel: channel, name: "Campanha 1") }

  def invoke_dedupe(*arguments)
    Rake::Task["tiktok:affiliate_messages:dedupe"].invoke(*arguments)
  end

  def stub_confirmation(answer)
    allow($stdin).to receive(:gets).and_return(answer)
  end

  describe "tiktok:affiliate_messages:dedupe" do
    # This is the exact scenario that broke in production (Hidrabene,
    # 2026-08-06): the orphan (no external_message_id) is referenced by an
    # AffiliateCampaignRecipient, and destroying it directly raises
    # ActiveRecord::InvalidForeignKey. The recipient must be repointed to
    # the matching "good" message (the one with external_message_id) BEFORE
    # the orphan is destroyed.
    it "repoints the AffiliateCampaignRecipient to the good message and removes the orphan, without raising InvalidForeignKey" do
      sent_at = Time.current
      good = creator.affiliate_messages.create!(
        external_message_id: "m-good", direction: "outbound", content: "oi", sent_at: sent_at
      )
      orphan = creator.affiliate_messages.create!(
        external_message_id: nil, direction: "outbound", content: "oi", sent_at: sent_at + 1.second
      )
      recipient = campaign.affiliate_campaign_recipients.create!(affiliate_creator: creator, affiliate_message: orphan)
      stub_confirmation("sim")

      expect { invoke_dedupe(tenant.slug) }.not_to raise_error

      expect(AffiliateMessage.exists?(orphan.id)).to eq(false)
      expect(AffiliateMessage.exists?(good.id)).to eq(true)
      expect(recipient.reload.affiliate_message_id).to eq(good.id)
    end

    it "does not touch anything when the operator does not confirm with 'sim'" do
      sent_at = Time.current
      good = creator.affiliate_messages.create!(
        external_message_id: "m-good", direction: "outbound", content: "oi", sent_at: sent_at
      )
      orphan = creator.affiliate_messages.create!(
        external_message_id: nil, direction: "outbound", content: "oi", sent_at: sent_at + 1.second
      )
      recipient = campaign.affiliate_campaign_recipients.create!(affiliate_creator: creator, affiliate_message: orphan)
      stub_confirmation("nao")

      invoke_dedupe(tenant.slug)

      expect(AffiliateMessage.exists?(orphan.id)).to eq(true)
      expect(AffiliateMessage.exists?(good.id)).to eq(true)
      expect(recipient.reload.affiliate_message_id).to eq(orphan.id)
    end

    it "leaves an orphan with no matching good message alone" do
      orphan = creator.affiliate_messages.create!(
        external_message_id: nil, direction: "outbound", content: "sem par", sent_at: Time.current
      )
      stub_confirmation("sim")

      expect { invoke_dedupe(tenant.slug) }.to output(/Nada para apagar/).to_stdout

      expect(AffiliateMessage.exists?(orphan.id)).to eq(true)
    end

    it "logs and continues to the next pair when one pair fails, instead of aborting the whole run" do
      sent_at = Time.current
      good1 = creator.affiliate_messages.create!(
        external_message_id: "m-good-1", direction: "outbound", content: "primeira", sent_at: sent_at
      )
      orphan1 = creator.affiliate_messages.create!(
        external_message_id: nil, direction: "outbound", content: "primeira", sent_at: sent_at + 1.second
      )
      good2 = creator.affiliate_messages.create!(
        external_message_id: "m-good-2", direction: "outbound", content: "segunda", sent_at: sent_at
      )
      orphan2 = creator.affiliate_messages.create!(
        external_message_id: nil, direction: "outbound", content: "segunda", sent_at: sent_at + 1.second
      )
      stub_confirmation("sim")
      allow_any_instance_of(AffiliateMessage).to receive(:destroy!) do |instance|
        raise ActiveRecord::RecordNotDestroyed, "boom" if instance.id == orphan1.id

        AffiliateMessage.delete(instance.id)
      end

      expect { invoke_dedupe(tenant.slug) }.to output(/ERRO id=#{orphan1.id}/).to_stdout

      expect(AffiliateMessage.exists?(orphan1.id)).to eq(true)
      expect(AffiliateMessage.exists?(orphan2.id)).to eq(false)
      expect(AffiliateMessage.exists?(good1.id)).to eq(true)
      expect(AffiliateMessage.exists?(good2.id)).to eq(true)
    end
  end
end
