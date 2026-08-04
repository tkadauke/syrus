require "rails_helper"

RSpec.describe ChatSessionRehydrator::Codex do
  include ActiveJob::TestHelper

  let(:user)    { Factories.user }
  let(:session) { ChatSession.create!(user: user) }

  before { allow(AppEvents).to receive(:broadcast) }

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def events_from(jsonl)
    ClaudeTranscript.new(jsonl).events.to_a
  end

  def create_message!(role:, content:, tool_name: nil, tool_use_id: nil)
    session.messages.create!(role: role, content: content, tool_name: tool_name, tool_use_id: tool_use_id)
  end

  def parsed_lines(jsonl)
    jsonl.lines.map { |l| JSON.parse(l) }
  end

  # ---------------------------------------------------------------------------
  # Unit: header and trailer
  # ---------------------------------------------------------------------------

  it "emits a thread.started line when session_id is supplied" do
    jsonl = described_class.new(session, session_id: "thread-1").call
    lines = parsed_lines(jsonl)

    expect(lines.first).to include("type" => "thread.started", "thread_id" => "thread-1")
  end

  it "always ends with a turn.completed line" do
    jsonl = described_class.new(session, session_id: "thread-1").call
    lines = parsed_lines(jsonl)

    expect(lines.last).to include("type" => "turn.completed")
  end

  it "reads session_id from claude_session when not given explicitly" do
    session.create_claude_session!(provider: "codex", session_id: "auto-thread")
    jsonl = described_class.new(session).call
    lines = parsed_lines(jsonl)

    expect(lines.first).to include("type" => "thread.started", "thread_id" => "auto-thread")
  end

  # ---------------------------------------------------------------------------
  # Unit: skipped roles
  # ---------------------------------------------------------------------------

  it "skips user ChatMessages (user prompt is passed directly to codex exec)" do
    create_message!(role: "user", content: { "text" => "Hello." })

    jsonl   = described_class.new(session, session_id: "t1").call
    events  = events_from(jsonl)

    expect(events.none? { |e| e.kind == :user_prompt }).to be true
  end

  it "skips system ChatMessages" do
    create_message!(role: "system", content: { "text" => "[mcp connected]" })

    jsonl  = described_class.new(session, session_id: "t1").call
    events = events_from(jsonl)

    expect(events.none? { |e| e.kind == :user_prompt }).to be true
  end

  # ---------------------------------------------------------------------------
  # Unit: assistant messages → agent_message items
  # ---------------------------------------------------------------------------

  it "emits an item.completed agent_message for an assistant ChatMessage" do
    create_message!(role: "assistant", content: [
      { "type" => "text", "text" => "Hello from Codex." }
    ])

    jsonl   = described_class.new(session, session_id: "t1").call
    events  = events_from(jsonl)
    texts   = events.select { |e| e.kind == :assistant_text }

    expect(texts.size).to eq(1)
    expect(texts.first.data[:text]).to eq("Hello from Codex.")
  end

  it "drops thinking blocks from assistant messages" do
    create_message!(role: "assistant", content: [
      { "type" => "thinking", "thinking" => "secret thoughts", "signature" => "sig" },
      { "type" => "text", "text" => "Public reply." }
    ])

    jsonl  = described_class.new(session, session_id: "t1").call
    raw    = jsonl
    lines  = parsed_lines(raw)
    items  = lines.select { |l| l.dig("item", "type") == "agent_message" }

    expect(items.size).to eq(1)
    expect(items.first.dig("item", "text")).to eq("Public reply.")
    expect(raw).not_to include("secret thoughts")
  end

  it "skips assistant messages that have only thinking blocks" do
    create_message!(role: "assistant", content: [
      { "type" => "thinking", "thinking" => "inner monologue", "signature" => "s" }
    ])

    jsonl  = described_class.new(session, session_id: "t1").call
    lines  = parsed_lines(jsonl)
    items  = lines.select { |l| l["type"]&.start_with?("item.") }

    expect(items).to be_empty
  end

  it "normalizes a legacy flat-format assistant message" do
    create_message!(role: "assistant", content: { "text" => "Legacy text." })

    jsonl   = described_class.new(session, session_id: "t1").call
    events  = events_from(jsonl)
    texts   = events.select { |e| e.kind == :assistant_text }

    expect(texts.size).to eq(1)
    expect(texts.first.data[:text]).to eq("Legacy text.")
  end

  # ---------------------------------------------------------------------------
  # Unit: mcp tool_use / tool_result
  # ---------------------------------------------------------------------------

  it "emits item.started + item.completed for an MCP tool call" do
    create_message!(role: "tool_use", tool_name: "syrus-chat-sidecar.submit_summary", tool_use_id: "mc1",
                    content: { "type" => "tool_use", "id" => "mc1",
                               "name" => "syrus-chat-sidecar.submit_summary",
                               "input" => { "pr_title" => "Add feature" } })
    create_message!(role: "tool_result", tool_name: "syrus-chat-sidecar.submit_summary", tool_use_id: "mc1",
                    content: { "type" => "tool_result", "tool_use_id" => "mc1",
                               "content" => "ok", "is_error" => false })

    jsonl  = described_class.new(session, session_id: "t1").call
    lines  = parsed_lines(jsonl)

    started   = lines.find { |l| l["type"] == "item.started"  && l.dig("item", "type") == "mcp_tool_call" }
    completed = lines.find { |l| l["type"] == "item.completed" && l.dig("item", "type") == "mcp_tool_call" }

    expect(started).not_to be_nil
    expect(started.dig("item", "server")).to eq("syrus-chat-sidecar")
    expect(started.dig("item", "tool")).to eq("submit_summary")
    expect(started.dig("item", "arguments")).to include("pr_title" => "Add feature")

    expect(completed).not_to be_nil
    expect(completed.dig("item", "result")).to eq("ok")
    expect(completed.dig("item", "status")).to eq("completed")
  end

  it "sets status=failed and uses error key for MCP tool errors" do
    create_message!(role: "tool_use", tool_name: "sidecar.some_tool", tool_use_id: "mc2",
                    content: { "type" => "tool_use", "id" => "mc2",
                               "name" => "sidecar.some_tool", "input" => {} })
    create_message!(role: "tool_result", tool_name: "sidecar.some_tool", tool_use_id: "mc2",
                    content: { "type" => "tool_result", "tool_use_id" => "mc2",
                               "content" => "something went wrong", "is_error" => true })

    jsonl     = described_class.new(session, session_id: "t1").call
    lines     = parsed_lines(jsonl)
    completed = lines.find { |l| l["type"] == "item.completed" && l.dig("item", "type") == "mcp_tool_call" }

    expect(completed.dig("item", "error")).to eq("something went wrong")
    expect(completed.dig("item", "status")).to eq("failed")
    expect(completed.dig("item", "result")).to be_nil
  end

  it "parses the rehydrated MCP tool events back via ClaudeTranscript correctly" do
    create_message!(role: "tool_use", tool_name: "syrus.inspect", tool_use_id: "mc3",
                    content: { "type" => "tool_use", "id" => "mc3",
                               "name" => "syrus.inspect", "input" => { "repo" => "acme/x" } })
    create_message!(role: "tool_result", tool_name: "syrus.inspect", tool_use_id: "mc3",
                    content: { "type" => "tool_result", "tool_use_id" => "mc3",
                               "content" => "repo info", "is_error" => false })

    jsonl    = described_class.new(session, session_id: "t1").call
    events   = events_from(jsonl)
    tool_use = events.find { |e| e.kind == :tool_use }
    result   = events.find { |e| e.kind == :tool_result }

    expect(tool_use).not_to be_nil
    expect(result).not_to be_nil
    expect(result.data[:tool_use_id]).to eq("mc3")
    expect(result.data[:error]).to be false
  end

  describe "admin repair transcript sequences" do
    def record_tool_call!(tool_name, tool_use_id, input:, result:)
      full_name = "syrus-chat-sidecar.#{tool_name}"
      create_message!(
        role: "tool_use",
        tool_name: full_name,
        tool_use_id: tool_use_id,
        content: {
          "type" => "tool_use",
          "id" => tool_use_id,
          "name" => full_name,
          "input" => input
        }
      )
      create_message!(
        role: "tool_result",
        tool_name: full_name,
        tool_use_id: tool_use_id,
        content: {
          "type" => "tool_result",
          "tool_use_id" => tool_use_id,
          "content" => JSON.generate(result),
          "is_error" => false
        }
      )
    end

    def rehydrated_mcp_items
      parsed_lines(described_class.new(session, session_id: "repair-thread").call)
        .select { |line| line["type"] == "item.completed" && line.dig("item", "type") == "mcp_tool_call" }
        .map { |line| line.fetch("item") }
    end

    shared_examples "a diagnostic-first repair transcript" do |params|
      incident = params.fetch(:incident)
      calls = params.fetch(:calls)
      repair_tool = params.fetch(:repair_tool)

      it "preserves diagnostic-first tool order for #{incident}" do
        calls.each_with_index do |call, index|
          record_tool_call!(
            call.fetch(:tool),
            "repair-#{index}",
            input: call.fetch(:input),
            result: call.fetch(:result)
          )
        end

        items = rehydrated_mcp_items
        tool_names = items.map { |item| item.fetch("tool") }

        expect(tool_names).to eq(calls.map { |call| call.fetch(:tool) })
        expect(tool_names.last).to eq(repair_tool)
        expect(tool_names[0...-1]).not_to include(repair_tool)

        repair_result = JSON.parse(items.last.fetch("result"))
        expect(repair_result).to include(
          "pending_action_id" => kind_of(Integer),
          "state" => "pending",
          "message" => a_string_including("JOB-")
        )
        expect(repair_result.keys).not_to include("before_snapshot", "after_snapshot")
      end
    end

    include_examples(
      "a diagnostic-first repair transcript",
      {
        incident: "JOB-2415 state drift",
        repair_tool: "reconcile_job_state",
        calls: [
        {
          tool: "read_job",
          input: { "job_id" => 2415 },
          result: { "job" => { "id" => 2415, "state" => "open" }, "links" => { "admin" => "/admin/jobs/2415" } }
        },
        {
          tool: "list_job_workflows",
          input: { "job_id" => 2415 },
          result: { "job_id" => 2415, "workflows" => [ { "id" => 15952, "state" => "succeeded" } ] }
        },
        {
          tool: "reconcile_job_state",
          input: { "job_id" => 2415, "mode" => "auto", "reason" => "State drift after terminal workflow." },
          result: { "pending_action_id" => 101, "state" => "pending", "message" => "Reconcile JOB-2415 using mode auto?" }
        }
        ]
      }
    )

    include_examples(
      "a diagnostic-first repair transcript",
      {
        incident: "JOB-2265 no-op CI repair",
        repair_tool: "mark_ci_repair_noop",
        calls: [
        {
          tool: "read_job",
          input: { "job_id" => 2265 },
          result: { "job" => { "id" => 2265, "pr_checks_state" => "failure" } }
        },
        {
          tool: "read_workflow",
          input: { "workflow_id" => 991 },
          result: { "workflow" => { "id" => 991, "trigger_kind" => "ci_failure", "state" => "succeeded" } }
        },
        {
          tool: "mark_ci_repair_noop",
          input: { "job_id" => 2265, "workflow_id" => 991, "reason" => "Repair produced no branch or check progress." },
          result: { "pending_action_id" => 102, "state" => "pending", "message" => "Mark CI repair no-op for JOB-2265?" }
        }
        ]
      }
    )

    include_examples(
      "a diagnostic-first repair transcript",
      {
        incident: "branch divergence",
        repair_tool: "retry_from_current_pr_branch",
        calls: [
        {
          tool: "read_workflow",
          input: { "workflow_id" => 992 },
          result: { "workflow" => { "id" => 992, "state" => "failed" }, "artifacts" => { "branch_divergence" => true } }
        },
        {
          tool: "get_job_diff",
          input: { "job_id" => 2301 },
          result: { "job_id" => 2301, "diff" => { "truncated" => true, "files" => 4 } }
        },
        {
          tool: "retry_from_current_pr_branch",
          input: { "job_id" => 2301, "workflow_id" => 992, "reason" => "Remote PR head supersedes stale workflow output." },
          result: { "pending_action_id" => 103, "state" => "pending", "message" => "Retry JOB-2301 from the current PR branch?" }
        }
        ]
      }
    )

    include_examples(
      "a diagnostic-first repair transcript",
      {
        incident: "stale active workflow",
        repair_tool: "cancel_stale_work",
        calls: [
        {
          tool: "admin_stuck_jobs",
          input: {},
          result: { "items" => [ { "id" => 2330, "workflow_id" => 993, "run_id" => 994, "attention_state" => "auto_repairable" } ] }
        },
        {
          tool: "explain_stuck_job",
          input: { "job_id" => 2330 },
          result: { "job_id" => 2330, "issues" => [ { "kind" => "running_run_without_live_worker_evidence" } ] }
        },
        {
          tool: "cancel_stale_work",
          input: { "job_id" => 2330, "workflow_ids" => [ 993 ], "run_ids" => [ 994 ], "reason" => "No live worker evidence for active run." },
          result: { "pending_action_id" => 104, "state" => "pending", "message" => "Cancel stale work for JOB-2330?" }
        }
        ]
      }
    )

    include_examples(
      "a diagnostic-first repair transcript",
      {
        incident: "wrong landing blocker",
        repair_tool: "force_landing_recheck",
        calls: [
        {
          tool: "read_job",
          input: { "job_id" => 2402 },
          result: { "job" => { "id" => 2402, "state" => "approved", "landing_queue_blocked_reason" => { "key" => "active_workflow" } } }
        },
        {
          tool: "read_queue",
          input: { "scope" => "landing" },
          result: { "landing" => [ { "job_id" => 2402, "blocked_reason" => "active_workflow" } ] }
        },
        {
          tool: "force_landing_recheck",
          input: { "job_id" => 2402, "reason" => "Refresh stale landing blocker before override." },
          result: { "pending_action_id" => 105, "state" => "pending", "message" => "Force landing recheck for JOB-2402? Current blocker: active_workflow." }
        }
        ]
      }
    )
  end

  # ---------------------------------------------------------------------------
  # Unit: bash tool_use → command_execution
  # ---------------------------------------------------------------------------

  it "maps bash tool_use rows to command_execution item events" do
    create_message!(role: "tool_use", tool_name: "bash", tool_use_id: "ce1",
                    content: { "type" => "tool_use", "id" => "ce1",
                               "name" => "bash", "input" => { "command" => "ls -la" } })
    create_message!(role: "tool_result", tool_name: "bash", tool_use_id: "ce1",
                    content: { "type" => "tool_result", "tool_use_id" => "ce1",
                               "content" => "file listing", "is_error" => false })

    jsonl     = described_class.new(session, session_id: "t1").call
    lines     = parsed_lines(jsonl)
    started   = lines.find { |l| l["type"] == "item.started"  && l.dig("item", "type") == "command_execution" }
    completed = lines.find { |l| l["type"] == "item.completed" && l.dig("item", "type") == "command_execution" }

    expect(started).not_to be_nil
    expect(started.dig("item", "command")).to eq("ls -la")

    expect(completed).not_to be_nil
    expect(completed.dig("item", "output")).to eq("file listing")
    expect(completed.dig("item", "status")).to eq("completed")
  end

  it "sets status=failed and uses error key for bash errors" do
    create_message!(role: "tool_use", tool_name: "bash", tool_use_id: "ce2",
                    content: { "type" => "tool_use", "id" => "ce2",
                               "name" => "bash", "input" => { "command" => "bad_cmd" } })
    create_message!(role: "tool_result", tool_name: "bash", tool_use_id: "ce2",
                    content: { "type" => "tool_result", "tool_use_id" => "ce2",
                               "content" => "command not found", "is_error" => true })

    jsonl     = described_class.new(session, session_id: "t1").call
    lines     = parsed_lines(jsonl)
    completed = lines.find { |l| l["type"] == "item.completed" && l.dig("item", "type") == "command_execution" }

    expect(completed.dig("item", "error")).to eq("command not found")
    expect(completed.dig("item", "status")).to eq("failed")
    expect(completed.dig("item", "output")).to be_nil
  end

  it "includes the original command in item.completed so ClaudeTranscript can recover it" do
    create_message!(role: "tool_use", tool_name: "bash", tool_use_id: "ce3",
                    content: { "type" => "tool_use", "id" => "ce3",
                               "name" => "bash", "input" => { "command" => "echo hi" } })
    create_message!(role: "tool_result", tool_name: "bash", tool_use_id: "ce3",
                    content: { "type" => "tool_result", "tool_use_id" => "ce3",
                               "content" => "hi", "is_error" => false })

    jsonl     = described_class.new(session, session_id: "t1").call
    lines     = parsed_lines(jsonl)
    completed = lines.find { |l| l["type"] == "item.completed" && l.dig("item", "type") == "command_execution" }

    expect(completed.dig("item", "command")).to eq("echo hi")
  end

  # ---------------------------------------------------------------------------
  # Round-trip spec
  # ---------------------------------------------------------------------------
  # Given a known-good Codex rollout JSONL, ingest it into ChatMessage rows
  # (as ChatTurnJob would), run the rehydrator, and verify structural equivalence.
  # ---------------------------------------------------------------------------

  describe "round-trip: Codex JSONL → ChatMessage rows → rehydrated JSONL" do
    let(:fixture_jsonl) do
      [
        { "type" => "thread.started", "thread_id" => "codex-thread-1",
          "model" => "gpt-5.5", "timestamp" => "2026-07-01T00:00:00Z" },
        { "type" => "item.completed", "id" => "msg-1",
          "timestamp" => "2026-07-01T00:00:01Z",
          "item" => { "type" => "agent_message", "id" => "msg-1",
                      "text" => "I'll inspect the repo.", "status" => "completed" } },
        { "type" => "item.started", "id" => "call-1",
          "timestamp" => "2026-07-01T00:00:02Z",
          "item" => { "type" => "mcp_tool_call", "call_id" => "call-1",
                      "server" => "syrus", "tool" => "inspect_repo",
                      "arguments" => { "slug" => "acme/widgets" } } },
        { "type" => "item.completed", "id" => "call-1",
          "timestamp" => "2026-07-01T00:00:03Z",
          "item" => { "type" => "mcp_tool_call", "call_id" => "call-1",
                      "server" => "syrus", "tool" => "inspect_repo",
                      "result" => { "stars" => 42 }, "status" => "completed" } },
        { "type" => "item.started", "id" => "cmd-1",
          "timestamp" => "2026-07-01T00:00:04Z",
          "item" => { "type" => "command_execution", "call_id" => "cmd-1",
                      "command" => "ls /tmp" } },
        { "type" => "item.completed", "id" => "cmd-1",
          "timestamp" => "2026-07-01T00:00:05Z",
          "item" => { "type" => "command_execution", "call_id" => "cmd-1",
                      "command" => "ls /tmp", "output" => "file.txt",
                      "status" => "completed" } },
        { "type" => "item.completed", "id" => "msg-2",
          "timestamp" => "2026-07-01T00:00:06Z",
          "item" => { "type" => "agent_message", "id" => "msg-2",
                      "text" => "Done.", "status" => "completed" } },
        { "type" => "turn.completed", "timestamp" => "2026-07-01T00:00:07Z" }
      ].map(&:to_json).join("\n") + "\n"
    end

    # Ingest fixture into ChatMessage rows as ChatTurnJob would.
    before do
      # First assistant text
      create_message!(role: "assistant", content: [
        { "type" => "text", "text" => "I'll inspect the repo." }
      ])
      # MCP tool call
      create_message!(role: "tool_use", tool_name: "syrus.inspect_repo", tool_use_id: "call-1",
                      content: { "type" => "tool_use", "id" => "call-1",
                                 "name" => "syrus.inspect_repo",
                                 "input" => { "slug" => "acme/widgets" } })
      create_message!(role: "tool_result", tool_name: "syrus.inspect_repo", tool_use_id: "call-1",
                      content: { "type" => "tool_result", "tool_use_id" => "call-1",
                                 "content" => { "stars" => 42 }, "is_error" => false })
      # Bash tool call
      create_message!(role: "tool_use", tool_name: "bash", tool_use_id: "cmd-1",
                      content: { "type" => "tool_use", "id" => "cmd-1",
                                 "name" => "bash", "input" => { "command" => "ls /tmp" } })
      create_message!(role: "tool_result", tool_name: "bash", tool_use_id: "cmd-1",
                      content: { "type" => "tool_result", "tool_use_id" => "cmd-1",
                                 "content" => "file.txt", "is_error" => false })
      # Final assistant text
      create_message!(role: "assistant", content: [
        { "type" => "text", "text" => "Done." }
      ])
    end

    it "rehydrated events are structurally equivalent to the original fixture events" do
      fixture_events    = events_from(fixture_jsonl).reject { |e| e.kind == :other }
      rehydrated_jsonl  = described_class.new(session, session_id: "codex-thread-1").call
      rehydrated_events = events_from(rehydrated_jsonl).reject { |e| e.kind == :other }

      # System init (thread.started)
      expect(rehydrated_events.first.kind).to eq(:system_init)
      expect(rehydrated_events.first.data[:session_id]).to eq("codex-thread-1")

      # Conversation events (excluding system_init and result/turn.completed)
      fixture_conv    = fixture_events.reject { |e| e.kind == :system_init || e.kind == :result }
      rehydrated_conv = rehydrated_events.reject { |e| e.kind == :system_init || e.kind == :result }

      expect(rehydrated_conv.map(&:kind)).to eq(fixture_conv.map(&:kind))

      # Assistant texts
      texts = rehydrated_conv.select { |e| e.kind == :assistant_text }.map { |e| e.data[:text] }
      expect(texts).to contain_exactly("I'll inspect the repo.", "Done.")

      # Tool use events — ClaudeTranscript emits :tool_use for both item.started
      # mcp_tool_call AND both item.started/item.completed command_execution,
      # so 3 :tool_use events in total (mcp-started, bash-started, bash-completed).
      tool_uses = rehydrated_conv.select { |e| e.kind == :tool_use }
      expect(tool_uses.size).to eq(3)

      # Tool result events — only the mcp_tool_call item.completed with a result
      # produces :tool_result; command_execution items always produce :tool_use.
      tool_results = rehydrated_conv.select { |e| e.kind == :tool_result }
      expect(tool_results.size).to eq(1)
      expect(tool_results.all? { |e| !e.data[:error] }).to be true
    end

    it "thinking blocks from the fixture are absent in rehydrated JSONL" do
      # Add a message with thinking (as if Claude ChatMessage was mixed in) —
      # should not appear in Codex output.
      create_message!(role: "assistant", content: [
        { "type" => "thinking", "thinking" => "codex has no thinking", "signature" => "s" },
        { "type" => "text", "text" => "Extra note." }
      ])

      rehydrated_jsonl = described_class.new(session, session_id: "codex-thread-1").call
      expect(rehydrated_jsonl).not_to include("codex has no thinking")
    end

    it "rehydrated JSONL ends with a turn.completed line" do
      rehydrated_jsonl = described_class.new(session, session_id: "codex-thread-1").call
      last_line        = JSON.parse(rehydrated_jsonl.lines.last)
      expect(last_line).to include("type" => "turn.completed")
    end
  end
end
