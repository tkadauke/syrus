require "rails_helper"

RSpec.describe "MCP control tool contracts" do
  it "publishes exact state and queue effects for each control" do
    expectations = {
      Mcp::Tools::OpenInCodingModeTool => [ "`implemented`, `approved`", "creates no", "Job, Workflow, WorkUnit, or pending action", "worker queue" ],
      Mcp::Tools::CompleteImplementStepTool => [ "must be `coding`", "creates only a pending action", "admission control/worker-queue" ],
      Mcp::Tools::EmergencyLandTool => [ "With job_id it lands an eligible", "job_id it captures the active", "chat worker without admission control", "a Workflow, or a WorkUnit" ],
      Mcp::Tools::RetryJobTool => [ "Candidate Job states are", "shared eligibility predicate", "admission control and worker-queue" ],
      Mcp::Tools::CancelJobTool => [ "Eligible states are", "creates only pending action", "without creating a Job" ],
      Mcp::Tools::ReenqueueWorkTool => [ "Workflow must be queued/running", "selected Run must", "be queued", "normal admission control" ],
      Mcp::Tools::ForceStateTransitionTool => [ "AASM may_<event>? guard", "creates only a pending action", "no Job, Workflow, WorkUnit" ],
      Mcp::Tools::SetJobPriorityTool => [ "any existing Job state", "needs no confirmation", "does not reorder" ],
      Mcp::Tools::SubmitCodingChangesTool => [ "Request time does not prove", "waits for operator confirmation", "auto-enqueues confirmation", "returns state `confirming`" ]
    }

    expectations.each do |tool, fragments|
      fragments.each do |fragment|
        expect(tool.description_value).to include(fragment), "#{tool.name} must document #{fragment.inspect}"
      end
    end
  end

  it "takes documented state lists from each owning eligibility service" do
    states = Job.aasm.states.map { |state| state.name.to_s }

    expect(RetryWorkflowEligibility::CANDIDATE_JOB_STATES).to eq(states - RetryWorkflowEligibility::INELIGIBLE_JOB_STATES)
    expect(JobCancellationEligibility::ELIGIBLE_STATES).to eq(states - JobCancellationEligibility::INELIGIBLE_STATES)
    expect(JobCodingMode::Takeover::CLAIMABLE_JOB_STATES).to eq(%w[implemented approved])
  end
end
