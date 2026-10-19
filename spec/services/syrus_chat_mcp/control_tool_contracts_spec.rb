require "rails_helper"

RSpec.describe "MCP control tool contracts" do
  it "publishes exact state and queue effects for each control" do
    expectations = {
      Mcp::Tools::OpenInCodingModeTool => [ "`implemented`, `approved`", "creates no", "Job, Workflow, WorkUnit, or pending action", "worker queue" ],
      Mcp::Tools::CompleteImplementStepTool => [ "must be `coding`", "creates only a pending action", "admission control/worker-queue" ],
      Mcp::Tools::EmergencyLandTool => [ "must be in `coding`", "does not require or read", "nothing enters admission control or the worker queue" ],
      Mcp::Tools::RetryJobTool => [ "Candidate Job states are", "shared eligibility predicate", "admission control and worker-queue" ],
      Mcp::Tools::CancelJobTool => [ "Eligible states are", "creates only pending action", "without creating a Job" ],
      Mcp::Tools::ReenqueueWorkTool => [ "Workflow must be queued/running", "selected Run must", "be queued", "normal admission control" ],
      Mcp::Tools::ForceStateTransitionTool => [ "AASM may_<event>? guard", "creates only a pending action", "no Job, Workflow, WorkUnit" ],
      Mcp::Tools::SetJobPriorityTool => [ "any existing Job state", "needs no confirmation", "does not reorder" ]
    }

    expectations.each do |tool, fragments|
      fragments.each do |fragment|
        expect(tool.description_value).to include(fragment), "#{tool.name} must document #{fragment.inspect}"
      end
    end
  end

  it "derives documented Job state lists from the Job state machine" do
    states = Job.aasm.states.map { |state| state.name.to_s }

    expect(Mcp::ControlToolContracts::JOB_STATES).to eq(states)
    expect(Mcp::ControlToolContracts::RETRY_JOB_STATES).to eq(states - %w[approved landing closed])
    expect(Mcp::ControlToolContracts::CANCEL_JOB_STATES).to eq(states - %w[closed])
  end
end
