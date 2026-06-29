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
        log_sink: ->(*, **) {},
        mcp_config: "/tmp/mcp.json",
        resume_session_id: "chat-session-0",
        stop_requested: -> { false },
        process_started: ->(_process) {}
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
        disallowed_tools: %w[Write Edit MultiEdit NotebookEdit],
        env: { "GIT_TERMINAL_PROMPT" => "0" }
      )
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
        raw_provider_transcript: "#{jsonl}\n",
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
        expect(capture.raw_provider_transcript).to eq("{\"type\":\"system\"}\n")
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
      expect(capture.raw_provider_transcript).to be_nil
      expect(capture.normalized_messages).to eq([])
      expect(capture.missing_message).to include("invalid Claude session id")
    end
  end
end
