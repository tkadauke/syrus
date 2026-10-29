require "rails_helper"

RSpec.describe Coworkers::MessageRateLimiter do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:maya) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-limit", workspace_repo: repository.remote_url) }
  let(:rin) { Coworkers::Coworker.create!(owner_user: owner, name: "Rin", handle: "rin-limit", workspace_repo: repository.remote_url) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:now) { Time.zone.parse("2026-10-29 10:04:00 UTC") }

  it "allows ten reservations and refuses the eleventh with the window retry time" do
    results = 11.times.map { described_class.reserve(sender: maya, receiver: rin, cache: cache, now: now) }

    expect(results.first(10)).to all(be_allowed)
    expect(results.last).not_to be_allowed
    expect(results.last.retry_after_seconds).to eq(6.minutes.to_i)
  end

  it "shares the same pair bucket in both directions" do
    described_class::LIMIT.times { described_class.reserve(sender: maya, receiver: rin, cache: cache, now: now) }

    expect(described_class.reserve(sender: rin, receiver: maya, cache: cache, now: now)).not_to be_allowed
  end

  it "starts a fresh bucket in the next window" do
    described_class::LIMIT.times { described_class.reserve(sender: maya, receiver: rin, cache: cache, now: now) }

    result = described_class.reserve(sender: maya, receiver: rin, cache: cache, now: now + described_class::WINDOW)

    expect(result).to be_allowed
  end
end
