require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe SwitchChatProviderJob do
  let(:user) { Factories.user(claude_oauth_token: "oat-test", agent_provider: "claude") }
  let(:chat) { ChatSession.create!(user: user) }

  it "enqueues on the chat queue" do
    expect {
      described_class.perform_later(chat.id, "codex")
    }.to have_enqueued_job(described_class).with(chat.id, "codex").on_queue("chat")
  end

  it "shares the same concurrency group and key as ChatTurnJob" do
    expect(described_class.concurrency_key.call(chat.id, "codex")).to eq("chat:#{chat.id}")
    expect(described_class.concurrency_group).to eq(ChatTurnJob::CONCURRENCY_GROUP)
  end

  describe "when a turn is in-flight" do
    before do
      chat.messages.create!(role: "user", content: { "text" => "hello" })
    end

    it "creates an error system message and broadcasts controls without switching" do
      broadcast_calls = []
      allow(AppEvents).to receive(:broadcast) { |**kwargs| broadcast_calls << kwargs }

      described_class.new.perform(chat.id, "claude")

      expect(chat.reload.chat_provider).to eq("claude")
      expect(chat.messages.where(role: "system").pluck(:content))
        .to include(include("text" => "Cannot switch provider while a turn is in progress."))
      expect(broadcast_calls.map { |c| c.dig(:payload, :action) }).to include("update_controls")
      expect(broadcast_calls.none? { |c| c.dig(:payload, :switching_provider) == true }).to be true
    end
  end

  describe "switching from claude to codex" do
    let(:tmpdir) { Dir.mktmpdir("switch-provider-test") }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("HOME").and_return(tmpdir)
      allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(Pathname.new(tmpdir).join("workspace"))
      chat.messages.create!(role: "user", content: { "text" => "hello" })
      chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "world" } ])
    end

    after { FileUtils.rm_rf(tmpdir) }

    it "updates chat_provider and creates a claude_session for codex" do
      allow(ChatSessionRehydrator::Codex).to receive(:new).and_call_original
      broadcast_payloads = []
      allow(AppEvents).to receive(:broadcast) { |**kwargs| broadcast_payloads << kwargs[:payload] }

      described_class.new.perform(chat.id, "codex")

      expect(chat.reload.chat_provider).to eq("codex")
      expect(chat.claude_session.provider).to eq("codex")
      expect(chat.claude_session.session_id).to be_present
      expect(chat.claude_session.transcript_jsonl).to be_present

      switching_on = broadcast_payloads.find { |p| p&.dig(:switching_provider) == true }
      switching_off = broadcast_payloads.find { |p| p&.dig(:action) == "update_controls" && p[:switching_provider] == false }
      expect(switching_on).to be_present
      expect(switching_off).to be_present
    end
  end

  describe "switching from codex to claude" do
    let(:tmpdir) { Dir.mktmpdir("switch-provider-test") }
    let(:workspace_path) { Pathname.new(tmpdir).join("workspace") }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("HOME").and_return(tmpdir)
      allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(workspace_path)
      chat.update!(chat_provider: "codex")
      chat.messages.create!(role: "user", content: { "text" => "hello" })
      chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "world" } ])
    end

    after { FileUtils.rm_rf(tmpdir) }

    it "writes the claude session to disk and updates claude_session" do
      described_class.new.perform(chat.id, "claude")

      expect(chat.reload.chat_provider).to eq("claude")
      session = chat.claude_session
      expect(session.provider).to eq("claude")
      session_id = session.session_id

      expected_path = ClaudeSession.canonical_path_for(
        home: tmpdir,
        cwd: workspace_path.to_s,
        session_id: session_id
      )
      expect(File.exist?(expected_path)).to be true
      expect(File.read(expected_path)).to eq(session.transcript_jsonl)
    end
  end

  describe "switching when chat has no messages" do
    it "updates chat_provider but does not create a claude_session" do
      allow(AppEvents).to receive(:broadcast)

      described_class.new.perform(chat.id, "codex")

      expect(chat.reload.chat_provider).to eq("codex")
      expect(chat.claude_session).to be_nil
    end
  end

  describe "updating an existing claude_session" do
    let(:tmpdir) { Dir.mktmpdir("switch-provider-test") }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("HOME").and_return(tmpdir)
      allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(Pathname.new(tmpdir).join("workspace"))
      chat.messages.create!(role: "user", content: { "text" => "hello" })
      chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "world" } ])
      chat.create_claude_session!(provider: "claude", session_id: "old-session-id", transcript_jsonl: "old-jsonl")
    end

    after { FileUtils.rm_rf(tmpdir) }

    it "updates the existing claude_session record" do
      allow(AppEvents).to receive(:broadcast)

      described_class.new.perform(chat.id, "codex")

      session = chat.reload.claude_session
      expect(session.provider).to eq("codex")
      expect(session.session_id).not_to eq("old-session-id")
      expect(session.transcript_jsonl).not_to eq("old-jsonl")
    end
  end

  describe "header broadcast after provider switch" do
    let(:tmpdir) { Dir.mktmpdir("switch-provider-test") }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("HOME").and_return(tmpdir)
      allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(Pathname.new(tmpdir).join("workspace"))
    end

    after { FileUtils.rm_rf(tmpdir) }

    it "fires the header broadcast with updated chat_provider when chat_provider changes" do
      header_broadcasts = []
      allow(AppEvents).to receive(:broadcast) do |**kwargs|
        header_broadcasts << kwargs[:payload] if kwargs.dig(:changed)&.include?("header")
      end

      described_class.new.perform(chat.id, "codex")

      expect(header_broadcasts).not_to be_empty
      latest = header_broadcasts.last
      expect(latest.dig(:chat, :chat_provider)).to eq("codex")
    end
  end
end
