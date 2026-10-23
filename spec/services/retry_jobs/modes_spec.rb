require "rails_helper"

RSpec.describe "RetryJobs modes" do
  it "keeps auto smart retry behavior and forces implementation mode to skip checkpoint resume" do
    job = Factories.job_record
    auto_result = RetryWorkflowEnqueuer::Result.new(workflow: instance_double(Workflow), error: nil, circuit: nil)
    implementation_result = RetryWorkflowEnqueuer::Result.new(workflow: instance_double(Workflow), error: nil, circuit: nil)

    allow(RetryWorkflowEnqueuer).to receive(:call).with(job: job).and_return(auto_result)
    allow(RetryWorkflowEnqueuer).to receive(:call)
      .with(job: job, resume_checkpoint: false, artifacts: {
        RebaseTarget::BASE_BRANCH_ARTIFACT => job.effective_base_branch,
        "skip_existing_branch_checkout" => true,
        "implementation_retry" => true
      })
      .and_return(implementation_result)

    expect(RetryJobs::Modes::Auto.new(job: job).execute).to eq(auto_result)
    expect(RetryJobs::Modes::Implementation.new(job: job).execute).to eq(implementation_result)
  end

  it "executes failed_step against the selected failed Workflow" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
    result = RetryFailedStepEnqueuer::Result.new(run: instance_double(Run), workflow: workflow,
      step: instance_double(Step), error: nil)
    allow(RetryFailedStepEnqueuer).to receive(:call).with(workflow: workflow).and_return(result)

    expect(RetryJobs::Modes::FailedStep.new(job: job, source_workflow_id: workflow.id).execute).to eq(result)
  end

  it "executes refresh_base with the selected checkpoint source and audit reason" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
    result = BaseRefreshRetryEnqueuer::Result.new(workflow: instance_double(Workflow), checkpoint: nil,
      error: nil, launch_result: nil)
    allow(BaseRefreshRetryEnqueuer).to receive(:call)
      .with(job: job, source_workflow: workflow, reason: "Emergency fix landed")
      .and_return(result)

    mode = RetryJobs::Modes::RefreshBase.new(job: job, source_workflow_id: workflow.id,
      reason: "Emergency fix landed")
    expect(mode.execute).to eq(result)
  end
end
