require "rails_helper"
require "tmpdir"

RSpec.describe ChatProviders::Agy do
  let(:user) { Factories.user(gemini_api_key: "AIza-test", github_token: "ghp-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:chat) { ChatSession.create!(repository: repository, user: user, chat_provider: "agy") }

  def result_fixture(**overrides)
    AgentInvocation::Result.new(**{
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: nil,
      session_id: "agy-conv-2"
    }.merge(overrides))
  end

  def agy_fixture(name)
    Rails.root.join("plugins/agy_agent/spec/fixtures/files/agy_transcripts/#{name}").read
  end

  around do |ex|
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    data_root = Dir.mktmpdir("syrus-agy-chat-provider")
    ENV["SYRUS_DATA_ROOT"] = data_root
    ex.run
  ensure
    ENV["SYRUS_DATA_ROOT"] = old_data_root
    FileUtils.rm_rf(data_root) if data_root
  end

  describe "plugin boundary" do
    it "implements the chat provider extension contract" do
      expect(described_class).to include(Syrus::Plugin::ChatProvider)
      expect(described_class.provider_key).to eq("agy")
      expect(described_class.provider).to eq("agy")
      expect(described_class.display_name).to eq("Antigravity")
      expect(described_class.available?).to eq(true)
    end

    it "is discoverable through ChatProviders" do
      expect(ChatProviders.for("agy")).to eq(described_class)
      expect(ChatProviders.provider_keys).to include("agy")
    end
  end

  describe "#credentials_missing?" do
    it "reports missing Antigravity credentials" do
      user.update!(gemini_api_key: nil)

      adapter = described_class.new(chat: chat)

      expect(adapter.credentials_missing?).to eq(true)
      expect(adapter.credentials_missing_message).to include("Antigravity credentials are missing")
    end
  end

  describe "#invoke" do
    it "invokes Agy with chat MCP servers, isolated home, resume transcript, and model settings" do
      chat.update!(chat_model: "gemini-test", chat_effort: "high")
      chat.create_provider_session!(
        provider: "agy",
        session_id: "agy-conv-1",
        transcript_jsonl: "{\"event\":\"init\",\"conversation_id\":\"agy-conv-1\"}\n"
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
      runner = ->(**kwargs) {
        received = kwargs
        result_fixture(transcript_jsonl: "{\"event\":\"result\",\"result\":\"ok\"}\n")
      }

      result = described_class.new(chat: chat, runner: runner).invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "What is the plan?",
        log_sink: ->(*, **) { },
        mcp_config: mcp_config.path,
        resume_session_id: "agy-conv-1",
        stop_requested: -> { false },
        process_started: ->(_process) { }
      )

      expect(result.session_id).to eq("agy-conv-2")
      expect(received).to include(
        workspace_path: "/tmp/chat-workspace",
        prompt: "What is the plan?",
        api_key: "AIza-test",
        agy_home: ChatWorkspace.agent_home_for(chat, "agy").to_s,
        resume_session_id: "agy-conv-1",
        resume_transcript_jsonl: "{\"event\":\"init\",\"conversation_id\":\"agy-conv-1\"}\n",
        model: "gemini-test",
        effort_level: "high"
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
    ensure
      mcp_config&.close!
    end

    it "rehydrates from chat messages when the provider session cache is missing" do
      chat.messages.create!(role: "assistant", content: [
        { "type" => "text", "text" => "Prior answer." }
      ])
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
        result_fixture
      }

      described_class.new(chat: chat, runner: runner).invoke(
        workspace_path: "/tmp/chat-workspace",
        prompt: "Continue",
        log_sink: ->(*, **) { },
        mcp_config: mcp_config.path,
        resume_session_id: "agy-conv-1",
        stop_requested: -> { false },
        process_started: ->(_process) { }
      )

      expect(received[:resume_transcript_jsonl]).to include("\"conversation_id\":\"agy-conv-1\"")
      expect(received[:resume_transcript_jsonl]).to include("Prior answer.")
    ensure
      mcp_config&.close!
    end

    it "raises a clear configuration error when invoked without a Gemini API key" do
      user.update!(gemini_api_key: nil)
      mcp_config = Tempfile.new([ "syrus-chat-mcp", ".json" ])
      mcp_config.write({ mcpServers: {} }.to_json)
      mcp_config.flush

      expect {
        described_class.new(chat: chat).invoke(
          workspace_path: "/tmp/chat-workspace",
          prompt: "Hello",
          log_sink: ->(*, **) { },
          mcp_config: mcp_config.path,
          resume_session_id: nil,
          stop_requested: -> { false },
          process_started: ->(_process) { }
        )
      }.to raise_error(ChatProviders::ConfigurationError, /Gemini API key/)
    ensure
      mcp_config&.close!
    end
  end

  describe "#session_capture" do
    it "normalizes captured Antigravity JSONL messages" do
      result = result_fixture(
        session_id: "agy-conv-3",
        transcript_jsonl: agy_fixture("chat_turn.jsonl")
      )

      capture = described_class.new(chat: chat).session_capture(result)

      expect(capture.provider).to eq("agy")
      expect(capture.session_id).to eq("agy-conv-3")
      expect(capture.normalized_messages).to include(
        { "role" => "user", "content" => "Hello Antigravity." },
        { "role" => "assistant", "content" => "I will inspect it." },
        { "role" => "tool_use", "content" => include(name: "mcp__syrus-chat-sidecar__read_live_state") },
        { "role" => "tool_result", "content" => include(tool_use_id: "tool-1", error: false) }
      )
    end

    it "returns a diagnostic when the session id is unsafe" do
      result = result_fixture(session_id: "../bad", transcript_jsonl: nil)

      capture = described_class.new(chat: chat).session_capture(result)

      expect(capture.transcript_jsonl).to be_nil
      expect(capture.normalized_messages).to eq([])
      expect(capture.missing_message).to include("invalid Antigravity session id")
    end
  end
end
