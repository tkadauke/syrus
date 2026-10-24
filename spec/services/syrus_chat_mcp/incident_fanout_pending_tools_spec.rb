require "rails_helper"

RSpec.describe "incident fan-out pending tools" do
  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin) }
  let(:chat_session) { ChatSession.create!(user: admin, repository: repository) }

  def call_tool(tool, arguments)
    server = MCP::Server.new(name: "syrus-chat-sidecar", tools: [ tool ], server_context: { chat_session: chat_session })
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: tool.tool_name, arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  def group_for(response)
    PendingActionGroup.find(response_payload(response).fetch(:pending_action_group_id))
  end

  it "groups workspace cleanup and one shared state transition" do
    jobs = [ Factories.job(user: admin, repository: repository), Factories.job(user: admin, repository: repository) ]
    workflows = jobs.map { |job| job.initial_run.step.workflow }

    cleanup = group_for(call_tool(Mcp::Tools::AdminCleanupWorkspaceTool, workflow_ids: workflows.map(&:id), reason: "Clean abandoned workspaces."))
    transition = group_for(call_tool(Mcp::Tools::ForceStateTransitionTool, job_ids: jobs.map(&:id), event: "force_fail", reason: "Repair shared state drift."))

    expect(cleanup.chat_pending_actions.map { |action| action.payload["workflow_id"] }).to contain_exactly(*workflows.map(&:id))
    expect(transition.chat_pending_actions.map(&:payload)).to contain_exactly(*jobs.map { |job| { "job_id" => job.id, "event" => "force_fail" } })
  end

  it "groups terminal WorkUnit retirement" do
    units = 2.times.map do
      job = Factories.job_record(user: admin, repository: repository, state: "implemented", pr_number: 42)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude", state: "blocked", finished_at: 5.minutes.ago)
      attach_work_unit(workflow, state: "blocked")
    end

    group = group_for(call_tool(Mcp::Tools::RetireTerminalWorkUnitTool, work_unit_ids: units.map(&:id), reason: "Release locks stranded by one worker incident."))

    expect(group.chat_pending_actions.map { |action| action.payload["work_unit_id"] }).to contain_exactly(*units.map(&:id))
  end

  it "copies one CI rerun policy while retaining each observed head" do
    jobs = [
      Factories.job_record(user: admin, repository: repository, state: "implemented", pr_number: 41),
      Factories.job_record(user: admin, repository: repository, issue_number: 43, state: "implemented", pr_number: 42)
    ]
    allow(CiRepair::CheckRefresh).to receive(:call) do |job|
      CiRepair::CheckRefresh::Result.new(
        job: job, head_sha: "head-#{job.id}", base_sha: "base", previous_state: "pending", state: "failing",
        detail: { failed_checks: [ { name: "spec", conclusion: "failure" } ] }, refreshed_at: Time.current
      )
    end

    group = group_for(call_tool(
      Mcp::Tools::RerunCiRepairTool,
      job_ids: jobs.map(&:id), reason: "Shared CI provider incident.", instructions: "Retry the affected check.", agent_provider: "codex"
    ))

    expect(group.chat_pending_actions.map { |action| action.payload["observed_head_sha"] }).to contain_exactly(*jobs.map { |job| "head-#{job.id}" })
    expect(group.chat_pending_actions.map { |action| action.payload.slice("instructions", "agent_provider") }.uniq).to eq(
      [ { "instructions" => "Retry the affected check.", "agent_provider" => "codex" } ]
    )
  end

  it "rejects plural inputs above the shared batch limit before creating a group" do
    response = call_tool(Mcp::Tools::AdminCleanupWorkspaceTool, workflow_ids: (1..101).to_a, reason: "Oversized incident batch.")

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to match(/100|at most 100 targets/)
    expect(PendingActionGroup.count).to eq(0)
  end
end
