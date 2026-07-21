require "rails_helper"

RSpec.describe Integrations::Tiktok::FinancialSyncLock do
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
    expect(described_class::RELEASE_SCRIPT).to include('redis.call("GET", KEYS[1]) == ARGV[1]')
    expect(described_class::RELEASE_SCRIPT).to include('redis.call("DEL", KEYS[1])')
  end
end
