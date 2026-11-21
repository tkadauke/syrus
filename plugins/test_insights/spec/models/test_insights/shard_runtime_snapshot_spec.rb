require "rails_helper"

RSpec.describe TestInsights::ShardRuntimeSnapshot do
  let(:repository) { Factories.job.repository }

  it "captures a round's profile once and returns it unchanged afterwards" do
    first = described_class.fetch(repository: repository, grader_key: "rspec-ci", source_snapshot_id: 7) { "a_spec.rb:1.00\n" }
    again = described_class.fetch(repository: repository, grader_key: "rspec-ci", source_snapshot_id: 7) { "a_spec.rb:9.00\n" }

    expect(again.id).to eq(first.id)
    expect(again.profile).to eq("a_spec.rb:1.00\n")
  end

  it "is pruned with the plugin's other retention data once past its window" do
    old = described_class.fetch(repository: repository, grader_key: "rspec-ci", source_snapshot_id: 1) { "x" }
    old.update_columns(created_at: (described_class::RETAIN_FOR + 1.day).ago)
    fresh = described_class.fetch(repository: repository, grader_key: "rspec-ci", source_snapshot_id: 2) { "y" }
    definition = RetentionPolicyRegistry.fetch(:test_insight_case)

    TestInsights::RetentionExecutor.new(definition).call

    expect(described_class.exists?(old.id)).to be(false)
    expect(described_class.exists?(fresh.id)).to be(true)
  end
end
