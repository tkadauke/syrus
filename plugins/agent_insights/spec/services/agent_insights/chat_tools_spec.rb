require "rails_helper"

# The chat-side half of the plugin's MCP surface: a repository chat can read
# and retire insights, but never author them -- authoring belongs to the
# insight run itself.
RSpec.describe Mcp::Sidecar, "agent insight chat tools" do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  before { enable!(false) }

  def enable!(enabled)
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: enabled, disableable: true)
  end

  def server_for(chat_session, tier: :all)
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: described_class.chat_tools(chat_session, tier: tier),
      server_context: { chat_session: chat_session }
    )
  end

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(server, name, arguments = {})
    jsonrpc(server, "tools/call", params: { name: name, arguments: arguments })
  end

    it "advertises insight read and retire tools via the deferred tools/list while the plugin is enabled" do
      enable!(true)

      server = server_for(chat_session, tier: :deferred)
      _ = jsonrpc(server, "initialize", id: 0)

      response = jsonrpc(server, "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |tool| tool[:name] }

      expect(tool_names).to include("list_insights", "read_insight", "retire_insight")
      expect(tool_names).not_to include("submit_insight", "update_insight")
    end

    it "does not advertise insight tools via the deferred tools/list while the plugin is disabled" do
      server = server_for(chat_session, tier: :deferred)
      _ = jsonrpc(server, "initialize", id: 0)

      response = jsonrpc(server, "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |tool| tool[:name] }

      expect(tool_names).not_to include("list_insights", "read_insight", "retire_insight", "submit_insight", "update_insight")
    end

    it "lets repository chats retire a pending insight with a superseding Job" do
      enable!(true)
      insight_job = Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
      target = AgentInsights::Suggestion.create!(
        job: insight_job,
        repository: repository,
        title: "Old chat-retirable insight",
        category: "configuration",
        severity: "low",
        confidence: 0.5
      )
      superseding_job = Factories.job(user: user, repository: repository)
      server = server_for(chat_session, tier: :deferred)
      _ = jsonrpc(server, "initialize", id: 0)

      expect {
        response = call_tool(
          server,
          "retire_insight",
          target_insight_id: target.id,
          reason: "Superseded by filed work.",
          superseded_by_job_id: superseding_job.id
        )

        expect(response.dig(:result, :isError)).to be_falsey
        expect(response.dig(:result, :content, 0, :text)).to include("retired")
      }.to change(AgentInsights::AuditEvent, :count).by(1)

      target.reload
      expect(target.state).to eq("retired")
      expect(target.retired_reason).to eq("Superseded by filed work.")
      expect(target.superseded_by_job_id).to eq(superseding_job.id)

      event = AgentInsights::AuditEvent.last
      expect(event.insight_suggestion).to eq(target)
      expect(event.event_type).to eq("retired")
      expect(event.actor_kind).to eq("user")
      expect(event.actor_user).to eq(user)
    end
end
