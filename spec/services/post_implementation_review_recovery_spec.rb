require "rails_helper"

RSpec.describe PostImplementationReviewRecovery do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:job) { Factories.job_record(user: user, state: "implemented", pr_number: 42) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded") }
  let(:step) { Step.create!(workflow: workflow, kind: "post_implementation_review", position: 10, state: "skipped") }
  let(:warning) do
    WorkflowWarning.create!(
      job: job, workflow: workflow, step: step,
      kind: PostImplementationReviewFailure::KIND,
      title: "Review failed", severity: "medium", state: "pending",
      evidence: { "run_id" => 123 }
    )
  end

  before { clear_enqueued_jobs }

  it "enqueues a review-only workflow and is idempotent while active" do
    first = described_class.retry(warning: warning, actor: user)
    second = described_class.retry(warning: warning.reload, actor: user)

    expect(first).to be_success
    expect(first.workflow).to eq(second.workflow)
    expect(first.workflow.trigger_kind).to eq("manual_post_implementation_review")
    expect(first.workflow.steps.map(&:kind)).to eq(%w[prepare post_implementation_review])
    expect(job.workflows.where(trigger_kind: "manual_post_implementation_review").count).to eq(1)
    expect(warning.reload.evidence).to include("latest_retry_workflow_id" => first.workflow.id)
  end

  it "explicitly skips idempotently while retaining audit evidence" do
    first = described_class.skip(warning: warning, actor: user)
    second = described_class.skip(warning: warning.reload, actor: user)

    expect(first).to be_success
    expect(second).to be_success
    expect(warning.reload).to be_dismissed
    expect(warning.evidence).to include("resolution" => "skipped", "resolved_by_id" => user.id)
  end
end
