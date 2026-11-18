require "rails_helper"

RSpec.describe PluginDesiredStateRevision do
  it "reads zero before the singleton row exists" do
    expect(described_class.current).to eq(0)
  end

  it "increments and persists the singleton revision after publication succeeds" do
    result = described_class.publish_next! { |revision| "published-#{revision}" }

    expect(result).to eq("published-1")
    expect(described_class.current).to eq(1)
  end

  it "does not advance the revision when publication fails" do
    expect {
      described_class.publish_next! { raise "storage unavailable" }
    }.to raise_error("storage unavailable")

    expect(described_class.current).to eq(0)
  end

  it "retries singleton creation races" do
    original = described_class.method(:find_or_create_by!)
    attempts = 0
    allow(described_class).to receive(:find_or_create_by!) do |*args, **kwargs, &block|
      attempts += 1
      raise ActiveRecord::RecordNotUnique if attempts == 1

      original.call(*args, **kwargs, &block)
    end

    expect { |publish| described_class.publish_next!(&publish) }.to yield_with_args(1)
    expect(attempts).to eq(2)
  end

  it "enforces the singleton key" do
    state = described_class.new(singleton_key: 2, revision: 0)

    expect(state).not_to be_valid
    expect(state.errors[:singleton_key]).to be_present
  end
end
