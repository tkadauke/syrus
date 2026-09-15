require "rails_helper"
require "tmpdir"

RSpec.describe ChatProviders::Muse do
  before do
    PluginRecord.find_or_create_by!(name: "muse_agent").update!(enabled: true, default_enabled: false, disableable: true)
  end

  let(:user) { Factories.user(muse_api_key: "muse-secret", github_token: "ghp-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:chat) { ChatSession.create!(repository: repository, user: user, chat_provider: "muse") }

  def result_fixture(**overrides)
    AgentInvocation::Result.new(**{
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: nil,
      session_id: nil
    }.merge(overrides))
  end

  around do |example|
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    data_root = Dir.mktmpdir("syrus-muse-chat-provider")
    ENV["SYRUS_DATA_ROOT"] = data_root
    example.run
  ensure
    ENV["SYRUS_DATA_ROOT"] = old_data_root
    FileUtils.rm_rf(data_root) if data_root
  end

  describe "plugin boundary" do
    it "implements the chat provider extension contract" do
      expect(described_class).to include(Syrus::Plugin::ChatProvider)
      expect(described_class.provider_key).to eq("muse")
      expect(described_class.provider).to eq("muse")
      expect(described_class.display_name).to eq("Muse Code")
      expect(described_class.available?).to eq(true)
    end
  end

  describe "#invoke" do
    it "invokes Muse with chat MCP servers, chat Muse home, callbacks, model, and effort" do
      chat.update!(chat_model: "muse-spark-test", chat_effort: "high")
      mcp_config = Tempfile.new([ "syrus-chat-mcp", ".json" ])
      mcp_config.write({
        mcpServers: {
          "syrus-chat-sidecar" => {
            type: "stdio",
            command: "/app/bin/syrus-chat-sidecar",
            args: [ "--tier", "essential" ],
            env: { "SYRUS_CHAT_SESSION_ID" => chat.id.to_s },
            alwaysLoad: true
          }
        }
      }.to_json)
      mcp_config.flush

      stop_requested = -> { false }
      process_started = ->(_process) { }
      invocation_kwargs = nil
      invocation_result = result_fixture(session_id: "muse-thread-1", transcript_jsonl: "{\"type\":\"event\"}\n")
      expect(MuseInvocation).to receive(:new) do |workspace_path, **kwargs|
        expect(workspace_path).to eq("/tmp/chat-workspace")
        invocation_kwargs = kwargs
        instance_double(MuseInvocation, run: invocation_result)
      end

      result = described_class.new(chat: chat, runner: ->(**_kwargs) { raise "runner should be passed through, not called directly" }).invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "What is the plan?",
        log_sink: ->(*, **) { },
        mcp_config: mcp_config.path,
        resume_session_id: "muse-thread-1",
        stop_requested: stop_requested,
        process_started: process_started
      )

      expect(result.session_id).to eq("muse-thread-1")
      expect(invocation_kwargs).to include(
        prompt: "What is the plan?",
        api_key: "muse-secret",
        runner: be_present,
        session_id: "muse-thread-1",
        model: "muse-spark-test",
        reasoning_effort: "high",
        transcript_policy: :exec_jsonl,
        muse_home: ChatWorkspace.agent_home_for(chat, "muse"),
        stop_requested: stop_requested,
        process_started: process_started
      )
      expect(invocation_kwargs[:mcp_server]).to eq(
        "syrus-chat-sidecar" => {
          command: "/app/bin/syrus-chat-sidecar",
          args: [ "--tier", "essential" ],
          env: { "SYRUS_CHAT_SESSION_ID" => chat.id.to_s }
        }
      )
    ensure
      mcp_config&.close!
    end

    it "retries as a fresh Muse session when resume fails before any turn runs" do
      mcp_config = Tempfile.new([ "syrus-chat-mcp", ".json" ])
      mcp_config.write({ mcpServers: { "syrus-chat-sidecar" => { command: "/app/bin/syrus-chat-sidecar" } } }.to_json)
      mcp_config.flush
      calls = []
      allow(MuseInvocation).to receive(:new) do |workspace_path, **kwargs|
        calls << [ workspace_path, kwargs ]
        result = if kwargs[:session_id].present?
          result_fixture(
            session_id: kwargs[:session_id],
            turns: 0,
            is_error: true,
            outcome: "session_not_found",
            final_text: "Muse session not found"
          )
        else
          result_fixture(session_id: "fresh-muse-session", turns: 1)
        end
        instance_double(MuseInvocation, run: result)
      end
      seen = []

      result = described_class.new(chat: chat).invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "Continue.",
        log_sink: ->(chunk = nil, **) { seen << chunk },
        mcp_config: mcp_config.path,
        resume_session_id: "stale-session",
        stop_requested: -> { false },
        process_started: ->(_process) { }
      )

      expect(result.session_id).to eq("fresh-muse-session")
      expect(calls.size).to eq(2)
      expect(calls.first.second[:session_id]).to eq("stale-session")
      expect(calls.second.second[:session_id]).to be_nil
      expect(calls.second.second[:prompt]).to include("You are Syrus Chat", "Continue.")
      expect(seen).to include(a_string_matching(/continuing from recent history/))
    ensure
      mcp_config&.close!
    end
  end

  describe ".invoke_event_evaluator" do
    it "supports scoped evaluator calls through the Muse adapter" do
      mcp_config = Tempfile.new([ "syrus-chat-evaluator-mcp", ".json" ])
      mcp_config.write({
        mcpServers: {
          "syrus-chat-evaluator-sidecar" => {
            type: "stdio",
            command: "/app/bin/syrus-chat-sidecar",
            args: [ "--tier", "evaluator" ],
            env: { "SYRUS_CHAT_SESSION_ID" => chat.id.to_s },
            alwaysLoad: true
          }
        }
      }.to_json)
      mcp_config.flush

      invocation_kwargs = nil
      invocation_result = result_fixture(session_id: "muse-evaluator-session", final_text: "{\"decision\":\"no_op\"}")
      runner = ->(**_kwargs) { raise "runner should be passed through, not called directly" }
      expect(MuseInvocation).to receive(:new) do |workspace_path, **kwargs|
        expect(workspace_path).to eq("/tmp/evaluator-workspace")
        invocation_kwargs = kwargs
        instance_double(MuseInvocation, run: invocation_result)
      end

      result = described_class.invoke_event_evaluator(
        chat_session: chat,
        workspace_path: "/tmp/evaluator-workspace",
        prompt: "Evaluate this event.",
        session_id: "muse-evaluator-session",
        transcript_jsonl: "{\"type\":\"event\"}\n",
        mcp_config: mcp_config.path,
        timeout: 30,
        max_turns: 2,
        runner: runner
      )

      expect(result.final_text).to include("no_op")
      expect(invocation_kwargs).to include(
        prompt: "Evaluate this event.",
        api_key: "muse-secret",
        runner: runner,
        timeout: 30,
        session_id: "muse-evaluator-session",
        max_model_steps: 2,
        transcript_policy: :exec_jsonl,
        muse_home: ChatWorkspace.agent_home_for(chat, "muse")
      )
      expect(invocation_kwargs[:mcp_server]).to include("syrus-chat-evaluator-sidecar")
    ensure
      mcp_config&.close!
    end

    it "includes the disposable transcript clone in the evaluator prompt" do
      transcript = ChatSessionRehydrator::Muse.new(
        chat,
        session_id: "muse-evaluator-session",
        messages: [
          ChatEventEvaluator::MessageSnapshot.new(
            id: 1,
            role: "user",
            content: { "text" => "recent context" },
            created_at: Time.current,
            tool_name: nil,
            tool_use_id: nil
          )
        ]
      ).call
      mcp_config = Tempfile.new([ "syrus-chat-evaluator-mcp", ".json" ])
      mcp_config.write({ mcpServers: { "syrus-chat-evaluator-sidecar" => { command: "/app/bin/syrus-chat-sidecar" } } }.to_json)
      mcp_config.flush

      invocation_kwargs = nil
      expect(MuseInvocation).to receive(:new) do |_workspace_path, **kwargs|
        invocation_kwargs = kwargs
        instance_double(MuseInvocation, run: result_fixture(session_id: "muse-evaluator-session"))
      end

      described_class.invoke_event_evaluator(
        chat_session: chat,
        workspace_path: "/tmp/evaluator-workspace",
        prompt: "Evaluate this event.",
        session_id: "muse-evaluator-session",
        transcript_jsonl: transcript,
        mcp_config: mcp_config.path,
        timeout: 30,
        max_turns: 2,
        runner: ->(**_kwargs) { }
      )

      expect(invocation_kwargs[:prompt]).to include("user: recent context")
    ensure
      mcp_config&.close!
    end
  end

  describe "#credentials_missing?" do
    it "reports missing Muse credentials" do
      user.update!(muse_api_key: nil)

      adapter = described_class.new(chat: chat)

      expect(adapter.credentials_missing?).to eq(true)
      expect(adapter.credentials_missing_message).to include("Muse credentials are missing")
    end
  end
end
