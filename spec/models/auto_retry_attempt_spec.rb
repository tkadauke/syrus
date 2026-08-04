require "rails_helper"

RSpec.describe AutoRetryAttempt, type: :model do
  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:run) { workflow.runs.first }

  def valid_attrs(overrides = {})
    {
      job: job,
      workflow: workflow,
      run: run,
      agent_provider: "claude",
      failure_classification: "worker_died",
      retry_kind: "failed_step",
      attempt_number: 1,
      scheduled_at: 5.minutes.from_now
    }.merge(overrides)
  end

  it "is valid with all required attributes" do
    attempt = described_class.new(valid_attrs)
    expect(attempt).to be_valid
  end

  it "requires an agent_provider" do
    expect(described_class.new(valid_attrs(agent_provider: nil))).not_to be_valid
  end

  it "rejects unknown agent providers" do
    expect(described_class.new(valid_attrs(agent_provider: "gpt-4"))).not_to be_valid
  end

  it "accepts all known agent providers" do
    User::AGENT_PROVIDERS.each do |provider|
      expect(described_class.new(valid_attrs(agent_provider: provider))).to be_valid
    end
  end

  it "requires a failure_classification" do
    expect(described_class.new(valid_attrs(failure_classification: nil))).not_to be_valid
  end

  it "requires a retry_kind" do
    expect(described_class.new(valid_attrs(retry_kind: nil))).not_to be_valid
  end

  it "rejects unknown retry kinds" do
    expect(described_class.new(valid_attrs(retry_kind: "teleport"))).not_to be_valid
  end

  it "accepts all known retry kinds" do
    AutoRetryAttempt::RETRY_KINDS.each do |kind|
      expect(described_class.new(valid_attrs(retry_kind: kind))).to be_valid
    end
  end

  it "requires attempt_number to be a positive integer" do
    expect(described_class.new(valid_attrs(attempt_number: 0))).not_to be_valid
    expect(described_class.new(valid_attrs(attempt_number: -1))).not_to be_valid
    expect(described_class.new(valid_attrs(attempt_number: 1))).to be_valid
  end

  it "requires scheduled_at" do
    expect(described_class.new(valid_attrs(scheduled_at: nil))).not_to be_valid
  end

  it "permits a nil run (optional association)" do
    expect(described_class.new(valid_attrs(run: nil))).to be_valid
  end

  describe ".budget_scope_for" do
    it "returns attempts matching job, provider, and failure classification" do
      attempt = described_class.create!(valid_attrs)
      described_class.create!(valid_attrs(agent_provider: "codex"))
      other_job = Factories.job
      described_class.create!(valid_attrs(job: other_job, workflow: other_job.latest_workflow, run: nil))

      scope = described_class.budget_scope_for(
        job: job,
        agent_provider: "claude",
        failure_classification: "worker_died"
      )

      expect(scope).to include(attempt)
      expect(scope.count).to eq(1)
    end

    it "excludes skipped attempts from retry budget accounting" do
      described_class.create!(valid_attrs(skipped_reason: "That agent is not available for retry."))

      scope = described_class.budget_scope_for(
        job: job,
        agent_provider: "claude",
        failure_classification: "worker_died"
      )

      expect(scope).to be_empty
    end
  end
end
