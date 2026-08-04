require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateCampaignDispatchJob do
  let(:tenant) { Tenant.create!(name: "Loja Job Campanha", slug: "loja-job-campanha-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:campaign) { tenant.affiliate_campaigns.create!(channel: channel, name: "Campanha", message_template: "Oi") }

  def stub_result(next_retry_at: nil)
    result = Integrations::Tiktok::AffiliateCampaignDispatchService::Result.new(outcome: :success, next_retry_at: next_retry_at)
    allow(Integrations::Tiktok::AffiliateCampaignDispatchService).to receive(:call).and_return(result)
    result
  end

  it "returns without calling the service when the campaign no longer exists" do
    allow(Integrations::Tiktok::AffiliateCampaignDispatchService).to receive(:call)

    described_class.new.perform(-1)

    expect(Integrations::Tiktok::AffiliateCampaignDispatchService).not_to have_received(:call)
  end

  it "does not schedule a continuation when there is no pending rate limit" do
    stub_result(next_retry_at: nil)
    allow(described_class).to receive(:set)

    described_class.new.perform(campaign.id)

    expect(described_class).not_to have_received(:set)
  end

  it "schedules a continuation at next_retry_at when the batch stopped on a rate limit" do
    next_retry_at = 40.seconds.from_now
    stub_result(next_retry_at: next_retry_at)
    configured_job = double("configured_job")
    allow(described_class).to receive(:set).and_return(configured_job)
    allow(configured_job).to receive(:perform_later)

    described_class.new.perform(campaign.id)

    expect(described_class).to have_received(:set) do |wait:|
      expect(wait).to be_within(1.second).of(next_retry_at - Time.current)
    end
    expect(configured_job).to have_received(:perform_later).with(campaign.id)
  end
end
