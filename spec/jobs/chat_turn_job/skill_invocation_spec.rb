require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe ChatTurnJob do
  let(:user) { Factories.user(claude_oauth_token: "oat-test", github_token: "ghp-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:chat) { ChatSession.create!(repository: repository, user: user) }
  let(:workspace_root) { Pathname.new(Dir.mktmpdir("syrus-chat-workspace")) }
  let(:workspace_path) { workspace_root.join("chat") }
  # A bare double (not is_a?(GithubClient)) so Skills' repo-local lookup
  # short-circuits straight to the built-in registry without hitting the
  # network, while with_git_askpass_env's `.access_token` call still works.
  let(:github_client_double) { double("GithubClient", access_token: "tok") }

  before do
    ChatTurnJob.agent_runner = nil
    allow(ChatWorkspace).to receive(:path_for).and_call_original
    allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(workspace_path)
    allow(ChatWorkspace).to receive(:ensure_coding_checkout!)
    allow(GithubClient).to receive(:for).and_return(github_client_double)
  end

  after do
    ChatTurnJob.agent_runner = nil
    FileUtils.rm_rf(workspace_root)
  end

  def enable_coding_mode!(enabled: true)
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: enabled)
  end

  def send_command(text)
    chat.messages.create!(role: "user", content: { text: text })
  end

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

  describe "when Coding Mode is required but not enabled" do
    it "posts a clear message and never invokes the agent, instead of silently degrading" do
      user_message = send_command("/investigate question=\"why is CI red?\"")
      agent_invoked = false
      ChatTurnJob.agent_runner = ->(**_) { agent_invoked = true; result_fixture(session_id: "s1") }

      described_class.perform_now(chat.id, user_message.id)

      expect(agent_invoked).to eq(false)
      message = chat.messages.order(:created_at, :id).last
      expect(message.role).to eq("system")
      expect(message.content["text"]).to include("Coding Mode")
      expect(message.content["text"]).to include("/investigate")
    end

    it "posts a clear message when Coding Mode is enabled instance-wide but this chat is still in planning mode" do
      enable_coding_mode!
      chat.update!(mode: "planning")
      user_message = send_command("/investigate question=\"why is CI red?\"")
      agent_invoked = false
      ChatTurnJob.agent_runner = ->(**_) { agent_invoked = true; result_fixture(session_id: "s1") }

      described_class.perform_now(chat.id, user_message.id)

      expect(agent_invoked).to eq(false)
      expect(chat.messages.order(:created_at, :id).last.content["text"]).to include("Coding Mode")
    end
  end

  describe "an unresolvable slash command" do
    it "posts a clear message naming the unknown skill instead of asking the agent to guess" do
      enable_coding_mode!
      chat.update!(mode: "coding")
      user_message = send_command("/does-not-exist foo=bar")
      agent_invoked = false
      ChatTurnJob.agent_runner = ->(**_) { agent_invoked = true; result_fixture(session_id: "s1") }

      described_class.perform_now(chat.id, user_message.id)

      expect(agent_invoked).to eq(false)
      message = chat.messages.order(:created_at, :id).last
      expect(message.content["text"]).to include("/does-not-exist")
      expect(message.content["text"]).to include(repository.slug)
    end

    it "posts a clear message when a required argument is missing" do
      enable_coding_mode!
      chat.update!(mode: "coding")
      user_message = send_command("/investigate")
      agent_invoked = false
      ChatTurnJob.agent_runner = ->(**_) { agent_invoked = true; result_fixture(session_id: "s1") }

      described_class.perform_now(chat.id, user_message.id)

      expect(agent_invoked).to eq(false)
      expect(chat.messages.order(:created_at, :id).last.content["text"]).to include("question")
    end
  end

  describe "a ready skill invocation" do
    it "records built-in provenance as a tool_use/tool_result pair and feeds the rendered skill instructions to the agent" do
      enable_coding_mode!
      chat.update!(mode: "coding")
      user_message = send_command('/investigate question="why is CI red?"')
      received = {}
      ChatTurnJob.agent_runner = ->(**kwargs) { received.merge!(kwargs); result_fixture(session_id: "s1") }

      described_class.perform_now(chat.id, user_message.id)

      provenance_use = chat.messages.find_by(role: "tool_use", tool_name: "resolve_skill")
      provenance_result = chat.messages.find_by(role: "tool_result", tool_name: "resolve_skill")
      expect(provenance_use.content.dig("input", "name")).to eq("investigate")
      expect(provenance_result.content.dig("content", "source")).to eq("built_in")
      expect(provenance_result.content.dig("content", "resolved_class")).to eq("Skills::Investigate")

      expect(received[:prompt]).to include("/investigate")
      expect(received[:prompt]).to include("why is CI red?")
      expect(received[:prompt]).to include("complete_implement_step")
    end

    it "completes cleanly with no diff when the skill is read-only and the agent makes no changes" do
      enable_coding_mode!
      chat.update!(mode: "coding")
      user_message = send_command('/investigate question="why is CI red?"')
      ChatTurnJob.agent_runner = ->(**kwargs) {
        kwargs[:log_sink].call("Nothing to change here.", kind: "assistant_text")
        result_fixture(session_id: "s1")
      }

      expect {
        described_class.perform_now(chat.id, user_message.id)
      }.not_to change(ChatPendingAction, :count)

      expect(Job.count).to eq(0)
      assistant_message = chat.messages.find_by(role: "assistant")
      expect(assistant_message.content.first).to include("type" => "text", "text" => "Nothing to change here.")
      expect(chat.messages.where(role: "system").any? { |message| message.content["text"].to_s.match?(/\Aagent turn failed/i) }).to eq(false)
    end

    it "still requires the existing Coding Mode handoff confirmation when the skill produces a diff" do
      enable_coding_mode!
      chat.update!(mode: "coding")
      user_message = send_command('/investigate question="why is CI red?"')
      ChatTurnJob.agent_runner = ->(**_) { result_fixture(session_id: "s1") }

      described_class.perform_now(chat.id, user_message.id)

      # Simulate the agent calling submit_coding_changes mid-turn after
      # committing a fix, exactly as it would for any other Coding Mode
      # change — slash-command immediacy applies to running the skill, not
      # to bypassing this gate.
      server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ Mcp::Tools::SubmitCodingChangesTool ],
        server_context: { chat_session: chat }
      )
      raw = server.handle_json({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "submit_coding_changes",
          arguments: {
            title: "Fix flaky spec",
            description: "Investigated and fixed the flaky spec.",
            branch: "syrus-chat-#{chat.id}",
            repository_id: repository.id
          }
        }
      }.to_json)
      response = JSON.parse(raw, symbolize_names: true)

      expect(response.dig(:result, :isError)).to be_falsey
      pending_action = chat.pending_actions.last
      expect(pending_action.action).to eq("submit_coding_changes")
      expect(pending_action.state).to eq("pending")
      expect(Job.count).to eq(0)
    end
  end
end
