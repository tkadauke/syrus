require "rails_helper"

RSpec.describe McpToolUsageRecorder do
  describe ".normalize" do
    it "normalizes Claude MCP tool names" do
      result = described_class.normalize("mcp__syrus-chat-sidecar__repo_info")

      expect(result.server_name).to eq("syrus-chat-sidecar")
      expect(result.tool_name).to eq("repo_info")
      expect(result.normalized_tool_name).to eq("repo_info")
    end

    it "normalizes Codex MCP tool names" do
      result = described_class.normalize("syrus-mcp-sidecar.read_live_state")

      expect(result.server_name).to eq("syrus-mcp-sidecar")
      expect(result.tool_name).to eq("read_live_state")
      expect(result.normalized_tool_name).to eq("read_live_state")
    end
  end

  describe ".advertised_tools" do
    it "derives chat and workflow advertised tools from the registry" do
      expect(described_class.advertised_tools(surface: "chat")).to eq(
        McpToolRegistry.summaries(surface: :chat).map { |entry| entry[:tool_name].to_s }.uniq.sort
      )
      expect(described_class.advertised_tools(surface: "workflow")).to eq(
        (McpToolRegistry.summaries(surface: :workflow) + McpToolRegistry.summaries(surface: :agent_insight))
          .map { |entry| entry[:tool_name].to_s }
          .uniq
          .sort
      )
    end
  end

  it "records workflow calls and completes them from Claude-style result ids" do
    run = Factories.job.initial_run

    described_class.record_workflow_tool_call(
      run: run,
      tool_name: "mcp__syrus-mcp-sidecar__submit_summary",
      tool_use_id: "toolu_1",
      tool_input: { "summary" => "Done" }
    )
    described_class.record_workflow_tool_result(
      run: run,
      tool_use_id: "toolu_1",
      content: [ { "type" => "text", "text" => "Saved." } ],
      error: false
    )

    usage = McpToolUsage.sole
    expect(usage).to have_attributes(
      surface: "workflow",
      provider: run.agent_provider,
      raw_tool_name: "mcp__syrus-mcp-sidecar__submit_summary",
      server_name: "syrus-mcp-sidecar",
      normalized_tool_name: "submit_summary",
      status: "completed",
      error: false,
      run_id: run.id,
      workflow_id: run.workflow_id,
      job_id: run.job_id
    )
    expect(usage.input_bytes).to be > 0
    expect(usage.result_bytes).to be > 0
    expect(usage.started_at).to be_present
    expect(usage.completed_at).to be_present
  end

  it "stores bounded error summaries without full result payloads" do
    run = Factories.job.initial_run

    described_class.record_workflow_tool_result(
      run: run,
      tool_name: "syrus-mcp-sidecar.read_live_state",
      tool_use_id: "toolu_err",
      content: { "message" => "x" * 1_000 },
      error: true
    )

    usage = McpToolUsage.sole
    expect(usage.status).to eq("failed")
    expect(usage.error).to eq(true)
    expect(usage.error_message_summary.length).to be <= McpToolUsage::ERROR_SUMMARY_MAX_LENGTH
  end

  it "tags workflow and chat convenience recorders with sidecar_mode=stdio by default" do
    run = Factories.job.initial_run

    described_class.record_workflow_tool_call(run: run, tool_name: "syrus-mcp-sidecar.read_live_state", tool_use_id: "t1", tool_input: {})

    expect(McpToolUsage.sole.sidecar_mode).to eq("stdio")
  end

  describe ".record_dispatch" do
    let(:chat_user) { Factories.user }
    let(:chat) { ChatSession.create!(user: chat_user, repository: Factories.repository(user: chat_user)) }

    it "records a completed persistent-mode call+result pair from a successful MCP::Tool::Response" do
      response = described_class.record_dispatch(
        surface: "chat", tool_name: "list_jobs", tool_input: { detail: "compact" },
        sidecar_mode: "persistent", daemon_identity: { worker_id: "w1" }, chat_session: chat
      ) { MCP::Tool::Response.new([ { type: "text", text: "{}" } ]) }

      expect(response).to be_a(MCP::Tool::Response)
      usage = McpToolUsage.sole
      expect(usage).to have_attributes(
        surface: "chat",
        normalized_tool_name: "list_jobs",
        status: "completed",
        error: false,
        sidecar_mode: "persistent",
        daemon_worker_id: "w1",
        chat_session_id: chat.id
      )
      expect(usage.input_bytes).to be > 0
      expect(usage.result_bytes).to be > 0
    end

    it "records a failed result from an MCP::Tool::Response with error: true, without raising" do
      described_class.record_dispatch(
        surface: "chat", tool_name: "admin_overview", tool_input: {},
        sidecar_mode: "persistent", daemon_identity: { worker_id: "w1" }, chat_session: chat
      ) { MCP::Tool::Response.new([ { type: "text", text: JSON.generate(error: "not_authorized") } ], error: true) }

      usage = McpToolUsage.sole
      expect(usage.status).to eq("failed")
      expect(usage.error).to eq(true)
      expect(usage.error_message_summary).to be_present
    end

    it "records a failed result with error_class and re-raises when the block raises" do
      expect {
        described_class.record_dispatch(
          surface: "chat", tool_name: "read_workflow", tool_input: {},
          sidecar_mode: "persistent", daemon_identity: { worker_id: "w1" }, chat_session: chat
        ) { raise McpInvocationContext::Expired, "invocation token expired" }
      }.to raise_error(McpInvocationContext::Expired)

      usage = McpToolUsage.sole
      expect(usage.status).to eq("failed")
      expect(usage.error).to eq(true)
      expect(usage.error_class).to eq("McpInvocationContext::Expired")
      expect(usage.error_message_summary).to eq("invocation token expired")
    end

    it "records without a chat_session when the invocation context never resolved one" do
      described_class.record_dispatch(
        surface: "chat", tool_name: "list_jobs", tool_input: {}, sidecar_mode: "persistent"
      ) { MCP::Tool::Response.new([], error: true) }

      usage = McpToolUsage.sole
      expect(usage.chat_session_id).to be_nil
      expect(usage.status).to eq("failed")
    end
  end
end
