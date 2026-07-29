require "rails_helper"

RSpec.describe "SyrusChatMcp workflow inspection tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::ListJobWorkflowsTool,
        SyrusChatMcp::ReadWorkflowTool,
        SyrusChatMcp::ReadRunTranscriptTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def build_workflow(job, trigger_kind:, summary: nil, run_summary: nil, run_count: 1, created_at: Time.current)
    workflow = Workflow.create!(job: job, trigger_kind: trigger_kind, created_at: created_at, started_at: created_at)
    workflow.set_artifact!("summary", summary) if summary
    step = workflow.steps.create!(kind: "implement", position: 0, state: "succeeded", started_at: created_at, finished_at: created_at + 1.minute)
    run_count.times do |index|
      step.runs.create!(
        job: job,
        trigger_kind: trigger_kind,
        state: "succeeded",
        agent_outcome: "success",
        agent_summary: run_summary || "run summary #{index}",
        agent_diff: "diff --git a/file b/file\n",
        cost_usd: BigDecimal("1.25"),
        started_at: created_at,
        finished_at: created_at + 1.minute
      )
    end
    workflow
  end

  describe "list_job_workflows" do
    it "returns a newest-first lightweight workflow index for a job" do
      job = Factories.job(repository: repository)
      job.workflows.update_all(created_at: 3.hours.ago)
      older = build_workflow(job, trigger_kind: "pr_comment", summary: "older summary", created_at: 2.hours.ago)
      newer = build_workflow(job, trigger_kind: "retry", run_summary: "newer run summary", run_count: 2, created_at: 1.hour.ago)

      response = call_tool("list_job_workflows", job_id: job.id)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      ids = payload[:workflows].map { |workflow| workflow[:id] }
      expect(ids).to start_with(newer.id, older.id)
      expect(payload[:workflows].first).to include(
        trigger_kind: "retry",
        state: "queued",
        summary: "newer run summary",
        step_count: 1,
        run_count: 2
      )
    end

    it "lists jobs outside the chat repository when they belong to the chat user" do
      other_job = Factories.job(repository: Factories.repository(user: user))

      response = call_tool("list_job_workflows", job_id: other_job.id)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload[:workflows].map { |workflow| workflow[:id] }).to include(other_job.latest_workflow.id)
    end

    it "allows an admin to list workflows for another user's job" do
      admin = Factories.user(admin: true)
      other_job = Factories.job(repository: Factories.repository(user: Factories.user))
      admin_session = ChatSession.create!(user: admin)
      admin_server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ SyrusChatMcp::ListJobWorkflowsTool ],
        server_context: { chat_session: admin_session }
      )

      raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_job_workflows", arguments: { job_id: other_job.id } } }.to_json)
      response = JSON.parse(raw, symbolize_names: true)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload[:workflows].map { |wf| wf[:id] }).to include(other_job.latest_workflow.id)
    end
  end

  describe "read_workflow" do
    it "returns workflow metadata with ordered steps and run summaries" do
      job = Factories.job(repository: repository)
      workflow = Workflow.create!(job: job, trigger_kind: "pr_comment", state: "running", started_at: 30.minutes.ago)
      first = workflow.steps.create!(kind: "prepare", position: 0, state: "succeeded", started_at: 30.minutes.ago, finished_at: 29.minutes.ago)
      second = workflow.steps.create!(kind: "respond", position: 1, state: "running", started_at: 28.minutes.ago)
      first.runs.create!(job: job, trigger_kind: "pr_comment", state: "succeeded", agent_summary: "prepared", started_at: 30.minutes.ago, finished_at: 29.minutes.ago)
      second.runs.create!(job: job, trigger_kind: "pr_comment", state: "running", agent_outcome: "in_progress", agent_summary: "x" * 600, cost_usd: BigDecimal("0.5"), started_at: 28.minutes.ago)

      response = call_tool("read_workflow", workflow_id: workflow.id)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload[:workflow]).to include(id: workflow.id, job_id: job.id, trigger_kind: "pr_comment", state: "running", step_count: 2, run_count: 2)
      expect(payload[:workflow][:steps].map { |step| step[:kind] }).to eq(%w[prepare respond])
      expect(payload[:workflow][:steps].last[:runs].first).to include(state: "running", agent_outcome: "in_progress", cost_usd: "0.5")
      expect(payload[:workflow][:steps].last[:runs].first[:agent_summary].length).to eq(500)
    end

    it "reads workflows outside the chat repository when they belong to the chat user" do
      other_job = Factories.job(repository: Factories.repository(user: user))
      workflow = other_job.latest_workflow

      response = call_tool("read_workflow", workflow_id: workflow.id)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload[:workflow]).to include(id: workflow.id, job_id: other_job.id)
    end
  end

  describe "read_run_transcript" do
    it "returns paginated transcript chunks and the full agent diff" do
      job = Factories.job(repository: repository)
      run = job.initial_run
      run.update!(agent_outcome: "success", agent_summary: "changed the code", agent_diff: "full diff\n" * 20)
      5.times { |index| run.job_logs.create!(sequence: index, kind: "stdout", chunk: "chunk-#{index}") }

      response = call_tool("read_run_transcript", run_id: run.id, page: 2, per: 2)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload).to include(run_id: run.id, run_state: run.state, agent_outcome: "success", agent_summary: "changed the code", total_chunks: 5, page: 2, per: 2, total_pages: 3)
      expect(payload[:agent_diff]).to eq("full diff\n" * 20)
      expect(payload[:chunks]).to eq([
        { sequence: 2, kind: "stdout", chunk: "chunk-2" },
        { sequence: 3, kind: "stdout", chunk: "chunk-3" }
      ])
    end

    it "reads runs outside the chat repository when they belong to the chat user" do
      other_job = Factories.job(repository: Factories.repository(user: user))

      response = call_tool("read_run_transcript", run_id: other_job.initial_run.id, per: 500)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload).to include(run_id: other_job.initial_run.id, per: 200)
    end

    it "caps per-page size at 200 chunks" do
      job = Factories.job(repository: repository)
      run = job.initial_run

      response = call_tool("read_run_transcript", run_id: run.id, page: 0, per: 500)
      payload = response_payload(response)

      expect(payload).to include(page: 1, per: 200)
    end
  end
end
