require "rails_helper"

RSpec.describe WorkUnits::WorkflowCancellation do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  it "cancels the workflow and records typed preemption on the owning work unit" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, idempotency_key: "cancel-spec")
    preempting_job = Factories.job_record(user: user, repository: repository)
    preempting = WorkUnits::Launcher.instantiate(kind: "initial", job: preempting_job, idempotency_key: "cancel-spec-keeper").work_unit

    described_class.cancel!(
      workflow,
      reason: Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON,
      by_work_unit: preempting,
      artifacts: { "cancelled_reason" => Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON }
    )

    expect(workflow.reload).to be_cancelled
    expect(workflow.artifact("cancelled_reason")).to eq(Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON)
    expect(workflow.work_unit.reload).to have_attributes(
      state: "cancelled",
      preemption_reason: Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON,
      preempted_by_work_unit_id: preempting.id
    )
  end

  it "preserves legacy cancellation for workflows without work units" do
    workflow = Workflows::Initial.instantiate(job: job)

    expect {
      described_class.cancel!(
        workflow,
        reason: "job_closed",
        artifacts: { "start_cancelled_reason" => "job_closed" }
      )
    }.not_to raise_error

    expect(workflow.reload).to be_cancelled
    expect(workflow.artifact("start_cancelled_reason")).to eq("job_closed")
  end
end
