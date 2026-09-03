require "rails_helper"

RSpec.describe Steps::AutoClose do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  # Any infrastructure Job kind exercises this step: it closes the anchor Job
  # with the Job's own kind as the closure reason, whoever owns that kind.
  let(:job) { Job.create!(user: user, repository: repository, kind: "main_grader", priority: "low") }
  let(:workflow) do
    Workflow.create!(job: job, user: user, trigger_kind: "main_grader", chain_template: [ "auto_close" ])
  end
  let(:step)    { Step.create!(workflow: workflow, kind: "auto_close", position: 0) }
  let(:run)     { Run.create!(job: job, user: user, step: step, trigger_kind: workflow.trigger_kind) }
  let(:handler) { described_class.new(run) }

  it "closes the anchor Job with the Job's kind as the closure reason" do
    handler.call

    expect(job.reload.state).to eq("closed")
    expect(job.closure_reason).to eq("main_grader")
  end

  it "is idempotent when the job is already closed" do
    run # materialize the workflow/step/run before the job closes
    job.close_with_reason!("main_grader")

    expect { handler.call }.not_to raise_error
    expect(job.reload.state).to eq("closed")
  end

  it "raises instead of silently succeeding when the Job doesn't actually close" do
    # Regression guard for JOB-3302: if the close attempt no-ops for any
    # reason, the step must surface that as a failure rather than let the
    # Run/Step report "succeeded" while the Job stays open.
    allow_any_instance_of(Job).to receive(:may_close?).and_return(false)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /not closed/)
    expect(job.reload.state).not_to eq("closed")
  end
end
