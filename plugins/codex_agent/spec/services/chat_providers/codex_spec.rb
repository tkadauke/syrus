require "rails_helper"
require "tmpdir"

RSpec.describe ChatProviders::Codex do
  let(:user) { Factories.user(codex_api_key: "sk-test", github_token: "ghp-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:chat) { ChatSession.create!(repository: repository, user: user, chat_provider: "codex") }

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

  around do |ex|
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    data_root = Dir.mktmpdir("syrus-codex-chat-provider")
    ENV["SYRUS_DATA_ROOT"] = data_root
    ex.run
  ensure
    ENV["SYRUS_DATA_ROOT"] = old_data_root
    FileUtils.rm_rf(data_root) if data_root
  end

  describe "plugin boundary" do
    it "implements the chat provider extension contract" do
      expect(described_class).to include(Syrus::Plugin::ChatProvider)
      expect(described_class.provider_key).to eq("codex")
      expect(described_class.provider).to eq("codex")
      expect(described_class.display_name).to eq("Codex")
      expect(described_class.available?).to eq(true)
    end
  end

  describe "#invoke" do
    it "invokes Codex with chat MCP servers, chat Codex home, and resume transcript" do
      chat.create_provider_session!(
        provider: "codex",
        session_id: "codex-thread-1",
        transcript_jsonl: "{\"type\":\"session_meta\"}\n"
      )
      mcp_config = Tempfile.new([ "syrus-chat-mcp", ".json" ])
      mcp_config.write({
        mcpServers: {
          "syrus-chat-sidecar" => {
            type: "stdio",
            command: "/app/bin/syrus-chat-sidecar",
            args: [ "--tier", "essential" ],
            env: { "SYRUS_CHAT_SESSION_ID" => chat.id.to_s },
            alwaysLoad: true
          },
          "syrus-chat-deferred-sidecar" => {
            type: "stdio",
            command: "/app/bin/syrus-chat-sidecar",
            args: [ "--tier", "deferred" ],
            env: { "SYRUS_CHAT_MCP_TOOL_TIER" => "deferred" },
            alwaysLoad: false
          }
        }
      }.to_json)
      mcp_config.flush

      received = nil
      timing_events = []
      allow(Rails.logger).to receive(:info) do |message|
        timing_events << message if message.include?("[codex startup]")
      end
      runner = ->(**kwargs) {
        received = kwargs
        result_fixture(session_id: "codex-thread-2", transcript_jsonl: "{\"type\":\"turn\"}\n")
      }

      result = described_class.new(chat: chat, runner: runner).invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "What is the plan?",
        log_sink: ->(*, **) { },
        mcp_config: mcp_config.path,
        resume_session_id: "codex-thread-1",
        stop_requested: -> { false },
        process_started: ->(_process) { }
      )

      expect(result.session_id).to eq("codex-thread-2")
      expect(received).to include(
        workspace_path: "/tmp/chat-workspace",
        prompt: "What is the plan?",
        api_key: "sk-test",
        codex_home: ChatWorkspace.agent_home_for(chat, "codex").to_s,
        resume_session_id: "codex-thread-1",
        resume_transcript_jsonl: "{\"type\":\"session_meta\"}\n"
      )
      expect(received[:mcp_servers]).to include(
        "syrus-chat-sidecar" => include(
          command: "/app/bin/syrus-chat-sidecar",
          args: [ "--tier", "essential" ],
          env: { "SYRUS_CHAT_SESSION_ID" => chat.id.to_s },
          required: true
        ),
        "syrus-chat-deferred-sidecar" => include(
          command: "/app/bin/syrus-chat-sidecar",
          args: [ "--tier", "deferred" ],
          env: { "SYRUS_CHAT_MCP_TOOL_TIER" => "deferred" },
          required: false
        )
      )
      expect(timing_events.join("\n")).to include(
        'stage="auth_refresh_lock"',
        'stage="auth_prepare"',
        'stage="auth_persist"'
      )
    ensure
      mcp_config&.close!
    end

    it "bypasses the cached full transcript for compacted chats" do
      allow(Feature).to receive(:chat_context_compaction_enabled?).and_return(true)
      allow_any_instance_of(ChatContextCompactor).to receive(:enabled_for_chat?).and_return(true)
      130.times do |i|
        chat.messages.create!(role: "assistant", content: [
          { "type" => "text", "text" => "assistant event #{i}" }
        ])
      end
      ChatContextCompactor.maybe_compact!(chat)
      chat.create_provider_session!(
        provider: "codex",
        session_id: "codex-thread-1",
        transcript_jsonl: "{\"type\":\"full_uncompacted_session\"}\n"
      )
      mcp_config = Tempfile.new([ "syrus-chat-mcp", ".json" ])
      mcp_config.write({
        mcpServers: {
          "syrus-chat-sidecar" => {
            type: "stdio",
            command: "/app/bin/syrus-chat-sidecar",
            args: [],
            env: {},
            alwaysLoad: true
          }
        }
      }.to_json)
      mcp_config.flush

      received = nil
      runner = ->(**kwargs) {
        received = kwargs
        result_fixture(session_id: "codex-thread-2", transcript_jsonl: "{\"type\":\"turn\"}\n")
      }

      described_class.new(chat: chat, runner: runner).invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "What changed?",
        log_sink: ->(*, **) { },
        mcp_config: mcp_config.path,
        resume_session_id: "codex-thread-1",
        stop_requested: -> { false },
        process_started: ->(_process) { }
      )

      expect(received[:resume_transcript_jsonl]).to include("Prior durable chat context summary")
      expect(received[:resume_transcript_jsonl]).to include("assistant event 129")
      expect(received[:resume_transcript_jsonl]).not_to include("full_uncompacted_session")
      expect(received[:resume_transcript_jsonl]).not_to include("assistant event 0")
    ensure
      mcp_config&.close!
    end
  end

  describe "#credentials_missing?" do
    it "reports missing Codex credentials" do
      user.update!(codex_api_key: nil)

      adapter = described_class.new(chat: chat)

      expect(adapter.credentials_missing?).to eq(true)
      expect(adapter.credentials_missing_message).to include("Codex credentials are missing")
    end
  end
end
