require "rails_helper"

RSpec.describe RetryJobs::Modes::FailedStep do
  it "requires guidance when repairing a no-progress grader loop" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job:, trigger_kind: "initial", state: "failed")
    workflow.steps.create!(kind: "grader_fanout", position: 1, state: "failed", loop_id: "grade")
    workflow.set_artifact!(GraderLoopProgress::STOP_ARTIFACT_KEY, {
      "reason" => GraderLoopProgress::NO_PROGRESS_REASON, "failing_set" => [ "frontend\0renders recovery" ]
    })

    result = described_class.new(job:, source_workflow_id: workflow.id).execute

    expect(result).not_to be_success
    expect(result.error).to include("Guidance is required")
  end

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
