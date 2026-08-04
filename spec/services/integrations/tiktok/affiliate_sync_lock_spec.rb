require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateSyncLock do
  let(:credential) do
    instance_double(ChannelCredential, tenant_id: 42, id: 7)
  end
  let(:redis) { instance_double("Redis") }

  before do
    allow(Sidekiq).to receive(:redis).and_yield(redis)
  end

  it "does not delete a lock owned by another token" do
    lock = described_class.new(credential)

    expect(redis).to receive(:call).with(
      "EVAL",
      described_class::RELEASE_SCRIPT,
      1,
      lock.key,
      lock.token
    ).and_return(0)

    expect(lock.release).to eq(0)
  end

  it "uses a key namespace distinct from the financial sync lock" do
    lock = described_class.new(credential)

    expect(lock.key).to eq("pricecom:tiktok:affiliate_sync:42:7")
  end
end
