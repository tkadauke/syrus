require "rails_helper"

RSpec.describe WorkUnits::TerminalLockCleanup do
  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin) }
  let(:job) { Factories.job_record(user: admin, repository: repository, state: "implemented", pr_number: 42) }

  def leaked_unit
    workflow = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude")
    unit = attach_work_unit(workflow, state: "blocked", blocked_reason: "active_work_lock")
    workflow.update_columns(state: "blocked", finished_at: Time.current)
    [ workflow, unit ]
  end

  it "retires terminal Workflow ownership without changing valid Job, PR, Workflow, or intent facts" do
    workflow, unit = leaked_unit
    intent = unit.work_intent
    result = described_class.call!(unit)
    expect(result).to be_eligible
    expect(unit.reload).to be_cancelled
    expect(unit.work_unit_locks.active).to be_empty
    expect(intent.reload).to be_requested
    expect(workflow.reload).to be_blocked
    expect(job.reload).to have_attributes(state: "implemented", pr_number: 42)
  end

  it "rejects active Runs and makes a repeated attempt ineligible" do
    workflow, unit = leaked_unit
    step = workflow.steps.create!(kind: "implement", position: 0, state: "running")
    step.runs.create!(job: job, user: admin, trigger_kind: "initial", agent_provider: "claude", state: "running")
    expect(described_class.preflight(unit)).not_to be_eligible
    expect { described_class.call!(unit) }.to raise_error(ArgumentError, /queued or running Runs/)
    workflow.runs.update_all(state: "cancelled", finished_at: Time.current)
    described_class.call!(unit)
    expect(described_class.preflight(unit.reload)).not_to be_eligible
  end

  it "exposes read-only dry-run facts without creating a confirmation" do
    workflow, unit = leaked_unit
    chat = ChatSession.create!(user: admin)
    server = MCP::Server.new(name: "test", tools: [ Mcp::Tools::RetireTerminalWorkUnitTool ], server_context: { chat_session: chat })
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "retire_terminal_work_unit", arguments: { work_unit_id: unit.id, dry_run: true } } }.to_json)
    response = JSON.parse(raw)
    payload = JSON.parse(response.dig("result", "content", 0, "text"))

    expect(payload).to include("outcome" => "noop")
    expect(payload.dig("preflight", "target")).to include("work_unit_id" => unit.id, "workflow_id" => workflow.id)
    expect(payload.dig("preflight", "expected_mutations")).to include("work_units" => 1, "locks" => unit.work_unit_locks.active.count)
    expect(ChatPendingAction.where(action: "retire_terminal_work_unit")).to be_empty
    expect(unit.reload).to be_blocked
  end
end
