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
    User.agent_providers.each do |provider|
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

  describe ".prune_stale_pending!" do
    it "skips pending attempts for terminal jobs" do
      attempt = described_class.create!(valid_attrs)
      job.update_columns(state: "closed", closure_reason: "pr_merged")

      expect {
        expect(described_class.prune_stale_pending!).to eq(1)
      }.to change { attempt.reload.skipped_reason }.from(nil).to("job is terminal")
    end

    it "skips pending attempts superseded by a newer successful workflow" do
      attempt = described_class.create!(valid_attrs)
      workflow.update_columns(state: "failed", finished_at: 10.minutes.ago)
      Workflow.create!(
        job: job,
        trigger_kind: "retry",
        state: "succeeded",
        created_at: 5.minutes.ago,
        started_at: 5.minutes.ago,
        finished_at: 4.minutes.ago
      )

      expect {
        expect(described_class.prune_stale_pending!).to eq(1)
      }.to change { attempt.reload.skipped_reason }.from(nil).to("source workflow was already superseded by a successful workflow")
    end

    it "does not prune active repair attempts superseded only by successful maintenance" do
      attempt = described_class.create!(valid_attrs(retry_kind: "retry_workflow"))
      workflow.update_columns(trigger_kind: "ci_failure", state: "failed", finished_at: 10.minutes.ago)
      Workflow.create!(
        job: job,
        trigger_kind: "rebase",
        state: "succeeded",
        created_at: 5.minutes.ago,
        started_at: 5.minutes.ago,
        finished_at: 4.minutes.ago
      )

      expect(described_class.prune_stale_pending!).to eq(0)
      expect(attempt.reload.skipped_reason).to be_nil
    end

    it "prunes active repair attempts superseded by newer successful validation" do
      attempt = described_class.create!(valid_attrs(retry_kind: "retry_workflow"))
      workflow.update_columns(trigger_kind: "ci_failure", state: "failed", finished_at: 10.minutes.ago)
      validated = Workflow.create!(
        job: job,
        trigger_kind: "retry",
        state: "succeeded",
        created_at: 5.minutes.ago,
        started_at: 5.minutes.ago,
        finished_at: 4.minutes.ago
      )
      validated.steps.create!(kind: "grader_collect", position: 0, state: "succeeded")

      expect {
        expect(described_class.prune_stale_pending!).to eq(1)
      }.to change { attempt.reload.skipped_reason }.from(nil).to("source workflow was already superseded by a successful workflow")
    end

    it "leaves still-actionable pending attempts alone" do
      attempt = described_class.create!(valid_attrs)

      expect(described_class.prune_stale_pending!).to eq(0)
      expect(attempt.reload.skipped_reason).to be_nil
    end
  end
end
