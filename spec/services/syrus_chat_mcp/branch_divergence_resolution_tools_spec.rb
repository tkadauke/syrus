require "rails_helper"

RSpec.describe "SyrusChatMcp branch divergence resolution tools" do
  include ActiveJob::TestHelper

  let(:admin) { Factories.user(admin: true, email_address: "admin@example.com") }
  let(:repository) { Factories.repository(user: admin, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: admin) }
  let(:job) do
    Factories.job_record(
      user: admin,
      repository: repository,
      state: "failed",
      branch_name: "syrus/direct-2562",
      pr_number: 2562,
      mergeability_head_sha: "remote-new",
      mergeability_base_sha: "base-sha"
    )
  end
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "retry", agent_provider: "claude", state: "failed") }

  before do
    workflow.set_artifact!("branch_divergence", {
      "branch" => "syrus/direct-2562",
      "remote_sha" => "remote-old",
      "local_sha" => "local-sha",
      "message" => "remote PR branch moved before push"
    })
  end

  def response_payload(response)
    JSON.parse(response.content.first[:text])
  end

  it "returns guardrail evidence in dry-run mode" do
    response = SyrusChatMcp::AdoptCurrentPrHeadTool.call(
      job_id: job.id,
      workflow_id: workflow.id,
      dry_run: true,
      server_context: { chat_session: chat_session }
    )
    payload = response_payload(response)

    expect(response).not_to be_error
    expect(payload.dig("evidence", "remote_sha")).to eq("remote-new")
    expect(payload.dig("evidence", "workflow_local_sha")).to eq("local-sha")
    expect(payload.dig("evidence", "base_sha")).to eq("base-sha")
    expect(payload.dig("evidence", "diff_summary", "available")).to be(false)
  end

  it "creates a pending adoption action with the evidence snapshot" do
    response = SyrusChatMcp::AdoptCurrentPrHeadTool.call(
      job_id: job.id,
      workflow_id: workflow.id,
      reason: "The current PR head already includes the requested repair.",
      server_context: { chat_session: chat_session }
    )
    action = ChatPendingAction.find(response_payload(response).fetch("pending_action_id"))

    expect(action).to have_attributes(
      action: "adopt_current_pr_head",
      reason: "The current PR head already includes the requested repair."
    )
    expect(action.payload).to include("job_id" => job.id, "workflow_id" => workflow.id)
    expect(action.payload.dig("evidence", "remote_sha")).to eq("remote-new")
  end

  it "requires exact destructive confirmation before creating a replacement action" do
    response = SyrusChatMcp::ReplacePrBranchWithWorkflowOutputTool.call(
      job_id: job.id,
      workflow_id: workflow.id,
      reason: "Workflow output is the desired branch state.",
      destructive_confirmation: "replace",
      server_context: { chat_session: chat_session }
    )
    payload = response_payload(response)

    expect(response).to be_error
    expect(payload).to include("error" => "missing_destructive_confirmation")
    expect(payload.dig("evidence", "workflow_local_sha")).to eq("local-sha")
    expect(chat_session.pending_actions.where(action: "replace_pr_branch_with_workflow_output")).to be_empty
  end

  it "confirms replacement by queueing the lease-guarded force-push job" do
    response = SyrusChatMcp::ReplacePrBranchWithWorkflowOutputTool.call(
      job_id: job.id,
      workflow_id: workflow.id,
      reason: "Workflow output is the desired branch state.",
      destructive_confirmation: "REPLACE PR BRANCH",
      server_context: { chat_session: chat_session }
    )
    action = ChatPendingAction.find(response_payload(response).fetch("pending_action_id"))

    expect(action).to have_attributes(action: "replace_pr_branch_with_workflow_output")
    expect {
      expect(action.confirm!).to be true
    }.to have_enqueued_job(BranchDivergenceRecoveryJob).with(workflow.id, admin.id)
    expect(workflow.reload.artifact("branch_divergence_recovery_pending")).to include(
      "action" => "force_push",
      "user_id" => admin.id
    )
  end

  it "confirms retry by starting a manual agentic run from the current PR branch" do
    allow(StepDispatcher).to receive(:start_workflow) do |new_workflow|
      new_workflow.first_step.runs.create!(
        job: job,
        trigger_kind: new_workflow.trigger_kind,
        agent_provider: new_workflow.agent_provider
      )
    end
    response = SyrusChatMcp::RetryFromCurrentPrBranchTool.call(
      job_id: job.id,
      workflow_id: workflow.id,
      instructions: "Reconcile only the migration change.",
      reason: "Remote PR branch moved after the failed workflow.",
      server_context: { chat_session: chat_session }
    )
    action = ChatPendingAction.find(response_payload(response).fetch("pending_action_id"))

    expect {
      expect(action.confirm!).to be true
    }.to change { job.workflows.where(trigger_kind: "manual_agentic_run").count }.by(1)

    new_workflow = action.reload.result
    expect(new_workflow.artifact("manual_agentic_run_base")).to eq("current_pr_branch")
    expect(new_workflow.artifact("manual_agentic_run_instructions")).to eq("Reconcile only the migration change.")
    expect(new_workflow.artifact("manual_agentic_run_push")).to be(true)
  end
end
