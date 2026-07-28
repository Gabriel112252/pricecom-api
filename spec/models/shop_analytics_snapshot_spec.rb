require "rails_helper"

RSpec.describe ShopAnalyticsSnapshot do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }

  it "is valid with a well-formed period" do
    snapshot = described_class.new(
      tenant: tenant, channel: channel, period_start: 30.days.ago.to_date, period_end: Date.current, synced_at: Time.current
    )

    expect(snapshot).to be_valid
  end

  it "is invalid when period_end is before period_start" do
    snapshot = described_class.new(
      tenant: tenant, channel: channel, period_start: Date.current, period_end: 1.day.ago.to_date, synced_at: Time.current
    )

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:period_end]).to be_present
  end

  it "enforces one snapshot per tenant/channel/period at the database level" do
    described_class.create!(
      tenant: tenant, channel: channel, period_start: 30.days.ago.to_date, period_end: Date.current, synced_at: Time.current
    )

    duplicate = described_class.new(
      tenant: tenant, channel: channel, period_start: 30.days.ago.to_date, period_end: Date.current, synced_at: Time.current
    )

    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
