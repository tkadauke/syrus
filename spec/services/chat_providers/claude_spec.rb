require "rails_helper"
require "tmpdir"

RSpec.describe ChatProviders::Claude do
  let(:user) { Factories.user(claude_oauth_token: "oat-test", github_token: "ghp-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:chat) { ChatSession.create!(repository: repository, user: user) }

  def result_fixture(**overrides)
    attrs = {
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: nil,
      session_id: nil
    }.merge(overrides)
    AgentInvocation::Result.new(**attrs)
  end

  describe "#invoke" do
    it "preserves the current Claude chat invocation contract" do
      received = nil
      runner = ->(**kwargs) {
        received = kwargs
        result_fixture(session_id: "chat-session-1", transcript_jsonl: "{}\n")
      }
      adapter = described_class.new(
        chat: chat,
        runner: runner,
        image_paths: [ "/tmp/capture.png" ],
        file_paths: [ "/tmp/brief.pdf" ],
        env: { "GIT_TERMINAL_PROMPT" => "0" }
      )

      result = adapter.invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "What is the plan?",
        log_sink: ->(*, **) { },
        mcp_config: "/tmp/mcp.json",
        resume_session_id: "chat-session-0",
        stop_requested: -> { false },
        process_started: ->(_process) { }
      )

      expect(result.session_id).to eq("chat-session-1")
      expect(received).to include(
        workspace_path: "/tmp/chat-workspace",
        prompt: "What is the plan?",
        oauth_token: "oat-test",
        max_turns: nil,
        mcp_config: "/tmp/mcp.json",
        image_paths: [ "/tmp/capture.png" ],
        file_paths: [ "/tmp/brief.pdf" ],
        resume_session_id: "chat-session-0",
        disallowed_tools: %w[Write Edit MultiEdit NotebookEdit AskUserQuestion],
        env: { "GIT_TERMINAL_PROMPT" => "0" }
      )
    end

    it "allows Write/Edit/MultiEdit in Coding Mode when the feature flag is on" do
      Feature.find_or_create_by!(slug: "coding_mode") { |f| f.category = "Labs"; f.name = "Coding Mode" }
              .update!(enabled: true)
      chat.update!(mode: "coding")

      received = nil
      runner = ->(**kwargs) { received = kwargs; result_fixture }
      adapter = described_class.new(chat: chat, runner: runner)

      adapter.invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "Fix the bug.",
        log_sink: ->(*, **) { },
        mcp_config: "/tmp/mcp.json",
        resume_session_id: nil,
        stop_requested: -> { false },
        process_started: ->(_process) { }
      )

      expect(received[:disallowed_tools]).to eq(%w[NotebookEdit AskUserQuestion])
    end

    it "keeps Write/Edit disallowed in Coding Mode when the feature flag is off" do
      Feature.find_or_create_by!(slug: "coding_mode") { |f| f.category = "Labs"; f.name = "Coding Mode" }
              .update!(enabled: false)
      chat.update!(mode: "coding")

      received = nil
      runner = ->(**kwargs) { received = kwargs; result_fixture }
      adapter = described_class.new(chat: chat, runner: runner)

      adapter.invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "Fix the bug.",
        log_sink: ->(*, **) { },
        mcp_config: "/tmp/mcp.json",
        resume_session_id: nil,
        stop_requested: -> { false },
        process_started: ->(_process) { }
      )

      expect(received[:disallowed_tools]).to eq(%w[Write Edit MultiEdit NotebookEdit AskUserQuestion])
    end

    it "keeps Write/Edit disallowed in Planning Mode even when the coding_mode flag is on" do
      Feature.find_or_create_by!(slug: "coding_mode") { |f| f.category = "Labs"; f.name = "Coding Mode" }
              .update!(enabled: true)

      received = nil
      runner = ->(**kwargs) { received = kwargs; result_fixture }
      adapter = described_class.new(chat: chat, runner: runner)

      adapter.invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "What is the plan?",
        log_sink: ->(*, **) { },
        mcp_config: "/tmp/mcp.json",
        resume_session_id: nil,
        stop_requested: -> { false },
        process_started: ->(_process) { }
      )

      expect(received[:disallowed_tools]).to eq(%w[Write Edit MultiEdit NotebookEdit AskUserQuestion])
    end

    it "retries WITHOUT --resume when a resume hard-fails at startup (stale session)" do
      calls = []
      runner = ->(**kwargs) {
        calls << kwargs
        if kwargs[:resume_session_id]
          # `claude --resume <gone>` dies immediately: is_error, zero turns.
          result_fixture(is_error: true, outcome: "error_during_execution", turns: 0)
        else
          result_fixture(session_id: "fresh-session", turns: 2)
        end
      }
      adapter = described_class.new(chat: chat, runner: runner)

      result = adapter.invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "Continue.",
        log_sink: ->(*, **) { },
        mcp_config: "/tmp/mcp.json",
        resume_session_id: "gone-session",
        stop_requested: -> { false },
        process_started: ->(_process) { }
      )

      expect(calls.size).to eq(2)
      expect(calls.first[:resume_session_id]).to eq("gone-session")
      expect(calls.last[:resume_session_id]).to be_nil
      expect(result.session_id).to eq("fresh-session")
      # The fresh session has no prior context, so the retry must carry the FULL
      # chat system prompt (the resume-mode prompt omits it).
      expect(calls.first[:prompt]).not_to include("You are Syrus Chat")
      expect(calls.last[:prompt]).to include("You are Syrus Chat")
      expect(calls.last[:prompt]).to include("Continue.")
    end

    it "does NOT retry when the resumed turn runs (turns > 0) even if it errors" do
      calls = []
      runner = ->(**kwargs) {
        calls << kwargs
        result_fixture(is_error: true, outcome: "error_during_execution", turns: 3, session_id: "chat-session-0")
      }
      adapter = described_class.new(chat: chat, runner: runner)

      adapter.invoke(
        workspace_path: "/tmp/chat-workspace", prompt: "Continue.",
        log_sink: ->(*, **) { }, mcp_config: "/tmp/mcp.json",
        resume_session_id: "chat-session-0",
        stop_requested: -> { false }, process_started: ->(_process) { }
      )

      expect(calls.size).to eq(1)
    end

    it "swallows the stale-resume startup noise from the thread during the resume attempt" do
      seen = []
      runner = ->(**kwargs) {
        if kwargs[:resume_session_id]
          # The failing resume streams the scary line, then its zero-turn result.
          kwargs[:log_sink].call("No conversation found with session ID: gone-session", kind: "system")
          kwargs[:log_sink].call("[result] subtype=error_during_execution, is_error=true, turns=0, duration_ms=0", kind: "system")
          result_fixture(is_error: true, outcome: "error_during_execution", turns: 0)
        else
          result_fixture(session_id: "fresh-session", turns: 1)
        end
      }
      adapter = described_class.new(chat: chat, runner: runner)

      adapter.invoke(
        workspace_path: "/tmp/chat-workspace", prompt: "Continue.",
        log_sink: ->(chunk = nil, **) { seen << chunk },
        mcp_config: "/tmp/mcp.json", resume_session_id: "gone-session",
        stop_requested: -> { false }, process_started: ->(_process) { }
      )

      expect(seen).not_to include(a_string_matching(/No conversation found/))
      expect(seen).not_to include(a_string_matching(/turns=0/))
      expect(seen).to include(a_string_matching(/continuing from recent history/))
    end
  end

  describe "#session_capture" do
    it "captures raw Claude JSONL and normalized replay messages" do
      jsonl = [
        { "type" => "user", "message" => { "content" => "Hello" } },
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "text", "text" => "Hi there" },
          { "type" => "tool_use", "name" => "repo_info", "input" => { "slug" => "acme/widgets" }, "id" => "toolu_1" }
        ] } },
        { "type" => "user", "message" => { "content" => [
          { "type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "ok", "is_error" => false }
        ] } }
      ].map(&:to_json).join("\n")

      capture = described_class.new(chat: chat).session_capture(
        result_fixture(session_id: "chat-session-1", transcript_jsonl: "#{jsonl}\n")
      )

      expect(capture).to have_attributes(
        provider: "claude",
        session_id: "chat-session-1",
        transcript_jsonl: "#{jsonl}\n",
        missing_message: nil
      )
      expect(capture.normalized_messages).to include(
        { "role" => "user", "content" => "Hello" },
        { "role" => "assistant", "content" => "Hi there" },
        { "role" => "tool_use", "content" => include(name: "repo_info", id: "toolu_1") },
        { "role" => "tool_result", "content" => include(tool_use_id: "toolu_1", error: false) }
      )
    end

    it "reads Claude's canonical JSONL path when the invocation result omits transcript data" do
      Dir.mktmpdir("syrus-chat-home") do |home|
        saved_home = ENV["HOME"]
        ENV["HOME"] = home
        workspace_path = Pathname.new(Dir.mktmpdir("syrus-chat-workspace"))
        allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(workspace_path)
        path = ClaudeSession.canonical_path_for(
          home: home,
          cwd: workspace_path,
          session_id: "chat-session-1"
        )
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "{\"type\":\"system\"}\n")

        capture = described_class.new(chat: chat).session_capture(result_fixture(session_id: "chat-session-1"))

        expect(capture.transcript_jsonl).to eq("{\"type\":\"system\"}\n")
      ensure
        ENV["HOME"] = saved_home
        FileUtils.rm_rf(workspace_path) if workspace_path
      end
    end

    it "does not read a transcript path for an unsafe session id" do
      expect(File).not_to receive(:read)

      capture = described_class.new(chat: chat).session_capture(result_fixture(session_id: "../outside"))

      expect(capture.provider).to eq("claude")
      expect(capture.session_id).to eq("../outside")
      expect(capture.transcript_jsonl).to be_nil
      expect(capture.normalized_messages).to eq([])
      expect(capture.missing_message).to include("invalid Claude session id")
    end
  end
end
