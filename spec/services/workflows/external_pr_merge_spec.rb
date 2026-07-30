require "rails_helper"

RSpec.describe Workflows::ExternalPrMerge do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  # external_pr Jobs must be created in :implemented state (validated on create).
  # Factories.job_record always overrides state to "closed" then update_columns,
  # so we use Job.create! directly for external_pr kind.
  let(:job) do
    Job.create!(
      user: user,
      owner_user: user,
      repository: repository,
      kind: "external_pr",
      issue_number: nil,
      external_pr_number: 99,
      state: "implemented"
    )
  end

  it "materializes the step chain without prepare or push" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[mergeability_preflight grader_fanout grader_collect external_pr_merge]
    )
  end

  it "uses the external_pr_merge trigger kind" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.trigger_kind).to eq("external_pr_merge")
  end

  it "enqueues on the merges queue" do
    expect(described_class.queue_name).to eq(:merges)
  end

  describe "after_fail" do
    it "calls LandingFailureHandler to revert the job to :implemented" do
      job.approve!(via: "operator")
      job.start_landing!
      job.save!
      workflow = described_class.instantiate(job: job)
      workflow.update!(state: "failed")

      expect(LandingFailureHandler).to receive(:call).with(
        job: job, reason: anything, run: nil
      )

      described_class.after_fail(workflow)
    end

    it "is a no-op when the job is not landing" do
      job.update_columns(state: "approved")
      workflow = described_class.instantiate(job: job)
      workflow.update!(state: "failed")

      expect(LandingFailureHandler).not_to receive(:call)

      described_class.after_fail(workflow)
    end
  end

  describe "after_success" do
    it "triggers the landing queue to process the next job" do
      workflow = described_class.instantiate(job: job)
      workflow.update!(state: "succeeded")

      expect(LandingQueueProcessor).to receive(:try_land!).with(no_args)

      described_class.after_success(workflow)
    end
  end
end
