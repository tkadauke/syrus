require "rails_helper"

RSpec.describe RetryJobs::Modes::FailedStep do
  let(:job) { Factories.job_record(state: "failed") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", agent_provider: job.agent_provider, state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago) }

  # The middle ground between restarting a grade loop blind and retrying
  # implementation from the base: the guidance lands in the Workflow the
  # repair round reads its operator context from, on the current branch.
  it "hands operator guidance to the retried workflow" do
    allow(RetryFailedStepEnqueuer).to receive(:call).and_return(RetryFailedStepEnqueuer::Result.new(run: :started, workflow: workflow, step: nil, error: nil))

    described_class.new(job: job, source_workflow_id: workflow.id, retry_context: "Add the two legacy entries.").execute

    expect(RetryFailedStepEnqueuer).to have_received(:call).with(workflow: workflow)
    expect(workflow.reload.artifact("replay_context")).to include("Add the two legacy entries.")
  end
end
