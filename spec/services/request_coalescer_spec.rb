require "rails_helper"

RSpec.describe RequestCoalescer do
  after { described_class.reset! }

  it "runs the block for a single caller and reports it as the leader" do
    result, coalesced = described_class.call("solo") { 42 }

    expect(result).to eq(42)
    expect(coalesced).to eq(false)
  end

  it "collapses concurrent calls for the same key into one block execution" do
    calls = Concurrent::AtomicFixnum.new(0)
    release = Queue.new
    entered = Queue.new

    leader = Thread.new do
      described_class.call("job:1:workflows") do
        calls.increment
        entered << true
        release.pop
        "computed-result"
      end
    end

    entered.pop # wait until the leader is inside the block before the follower joins

    follower_result = nil
    follower_coalesced = nil
    follower = Thread.new do
      follower_result, follower_coalesced = described_class.call("job:1:workflows") { calls.increment; "follower-should-not-run" }
    end

    # Give the follower a moment to register as a waiter before releasing the leader.
    sleep 0.05
    release << true

    leader_result, leader_coalesced = leader.value
    follower.join

    expect(calls.value).to eq(1)
    expect(leader_result).to eq("computed-result")
    expect(leader_coalesced).to eq(false)
    expect(follower_result).to eq("computed-result")
    expect(follower_coalesced).to eq(true)
  end

  it "does not collapse calls for different keys" do
    calls = Concurrent::AtomicFixnum.new(0)

    results = [ "a", "b" ].map do |key|
      Thread.new { described_class.call(key) { calls.increment } }
    end.map(&:value)

    expect(calls.value).to eq(2)
    expect(results.map(&:first)).to contain_exactly(1, 2)
    expect(results.map(&:last)).to eq([ false, false ])
  end

  it "propagates the leader's error to every waiter and clears the entry so a later call can retry" do
    release = Queue.new
    entered = Queue.new

    leader = Thread.new do
      described_class.call("job:1:workflows") do
        entered << true
        release.pop
        raise "boom"
      end
    end

    entered.pop

    follower = Thread.new { described_class.call("job:1:workflows") { "unreachable" } }
    sleep 0.05
    release << true

    expect { leader.value }.to raise_error("boom")
    expect { follower.value }.to raise_error("boom")

    result, coalesced = described_class.call("job:1:workflows") { "fresh" }
    expect(result).to eq("fresh")
    expect(coalesced).to eq(false)
  end
end
