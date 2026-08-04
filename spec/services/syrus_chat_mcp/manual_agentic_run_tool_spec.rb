require "rails_helper"

RSpec.describe SyrusChatMcp::ManualAgenticRunTool do
  let(:admin) { Factories.user(admin: true, email_address: "admin@example.com") }
  let(:repository) { Factories.repository(user: admin) }
  let(:chat_session) { ChatSession.create!(user: admin) }
  let(:job) do
    Factories.job_record(
      user: admin,
      repository: repository,
      state: "implemented",
      branch_name: "syrus/direct-2561",
      pr_number: 2561
    )
  end

  def response_text(response)
    response.content.first[:text]
  end

  it "creates a pending confirmation with base, instructions, push, and reason" do
    response = described_class.call(
      job_id: job.id,
      base: "current_pr_branch",
      instructions: "Repair only the failing migration-lint check.",
      reason: "Operator wants a focused repair.",
      server_context: { chat_session: chat_session }
    )
    payload = JSON.parse(response_text(response))
    action = ChatPendingAction.find(payload.fetch("pending_action_id"))

    expect(response).not_to be_error
    expect(action).to have_attributes(
      action: "manual_agentic_run",
      requested_by: "agent",
      reason: "Operator wants a focused repair.",
      repository: nil
    )
    expect(action.payload).to include(
      "job_id" => job.id,
      "base" => "current_pr_branch",
      "instructions" => "Repair only the failing migration-lint check.",
      "push" => true
    )
  end

  it "returns a structured non-500 error for unavailable failed workspaces" do
    response = described_class.call(
      job_id: job.id,
      base: "failed_workflow_workspace",
      instructions: "Inspect the failed workspace.",
      reason: "Operator wants diagnosis.",
      server_context: { chat_session: chat_session }
    )
    payload = JSON.parse(response_text(response))

    expect(response).to be_error
    expect(payload).to include(
      "error" => "failed_workflow_workspace_unavailable",
      "valid_bases" => %w[current_pr_branch fresh_checkout]
    )
    expect(chat_session.pending_actions.where(action: "manual_agentic_run")).to be_empty
  end

  it "confirms by dispatching the manual agentic workflow with audit snapshots" do
    allow(StepDispatcher).to receive(:start_workflow) do |workflow|
      workflow.first_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    end
    response = described_class.call(
      job_id: job.id,
      base: "current_pr_branch",
      instructions: "Inspect the failing rspec check.",
      reason: "Operator wants focused repair.",
      server_context: { chat_session: chat_session }
    )
    action = ChatPendingAction.find(JSON.parse(response_text(response)).fetch("pending_action_id"))

    expect {
      expect(action.confirm!).to be true
    }.to change { job.workflows.where(trigger_kind: "manual_agentic_run").count }.by(1)

    workflow = action.reload.result
    expect(workflow).to have_attributes(job: job, trigger_kind: "manual_agentic_run")
    expect(workflow.artifact("manual_agentic_run_instructions")).to eq("Inspect the failing rspec check.")
    expect(action.before_snapshot).to include("jobs")
    expect(action.after_snapshot).to include("jobs")
    expect(StepDispatcher).to have_received(:start_workflow).with(workflow)
  end
end
