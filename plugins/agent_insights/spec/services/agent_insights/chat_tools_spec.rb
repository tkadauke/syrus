require "rails_helper"

# The chat-side half of the plugin's MCP surface: a repository chat can read
# and retire insights, but never author them -- authoring belongs to the
# insight run itself.
RSpec.describe Mcp::Sidecar, "agent insight chat tools" do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:coworker) do
    instance_double(
      "CoworkerActor",
      kind: "coworker",
      permission_rules: instance_double("PermissionRules", entries: [])
    )
  end

  before { enable!(false) }

  def enable!(enabled)
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: enabled, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  def server_for(chat_session, tier: :all, agent_actor: nil)
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: described_class.chat_tools(chat_session, tier: tier, agent_actor: agent_actor),
      server_context: { chat_session: chat_session, agent_actor: agent_actor }
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

  it "advertises only read-only insight tools to coworkers on the deferred tier" do
    enable!(true)
    allow(AgentInsights::ChatToolSet).to receive(:coworker_chat?).with(chat_session).and_return(true)

    essential_names = described_class.chat_tools(chat_session, tier: :essential, agent_actor: coworker)
      .map { |tool| McpToolRegistry.tool_name_for(tool) }
    deferred_names = described_class.chat_tools(chat_session, tier: :deferred, agent_actor: coworker)
      .map { |tool| McpToolRegistry.tool_name_for(tool) }

    expect(essential_names).not_to include("list_insights", "read_insight")
    expect(deferred_names).to include("list_insights", "read_insight")
    expect(deferred_names).not_to include(
      "accept_insight", "dismiss_insight", "retire_insight", "submit_insight", "update_insight"
    )
  end

  it "classifies coworker insight reads in the catalog without requiring a grant" do
    enable!(true)
    allow(McpToolContext).to receive(:from_chat_session).with(chat_session).and_return(
      instance_double(McpToolContext, role: AgentRole::COWORKER_CHAT)
    )

    descriptors = Mcp::CoworkerToolCatalog.all(chat_session: chat_session)
      .select { |descriptor| %w[list_insights read_insight].include?(descriptor.tool_name) }

    expect(descriptors.map(&:tool_name)).to contain_exactly("list_insights", "read_insight")
    expect(descriptors).to all(have_attributes(tier: :deferred, ungated: true, availability_state: :available))
  end

  it "keeps coworker reads scoped to attached repositories without leaking inaccessible insights" do
    enable!(true)
    allow(AgentInsights::ChatToolSet).to receive(:coworker_chat?).with(chat_session).and_return(true)
    visible_job = Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
    visible = AgentInsights::Suggestion.create!(
      job: visible_job, repository: repository, title: "Visible finding",
      category: "configuration", severity: "low", confidence: 0.5,
      suggested_prompt: "File visible work", memory_suggestion: "Remember visible context"
    )
    hidden_repository = Factories.repository(user: Factories.user)
    hidden_job = Job.create!(user: hidden_repository.user, repository: hidden_repository, kind: "agent_insight", priority: "low")
    hidden = AgentInsights::Suggestion.create!(
      job: hidden_job, repository: hidden_repository, title: "Hidden finding",
      category: "secret", severity: "low", confidence: 0.5,
      suggested_prompt: "Private prompt", memory_suggestion: "Private memory"
    )
    server = server_for(chat_session, tier: :deferred, agent_actor: coworker)
    _ = jsonrpc(server, "initialize", id: 0)

    listed = call_tool(server, "list_insights")
    read_visible = call_tool(server, "read_insight", id: visible.id)
    read_hidden = call_tool(server, "read_insight", id: hidden.id)
    forbidden_repository = call_tool(server, "list_insights", repository_id: hidden_repository.id)

    expect(listed.dig(:result, :content, 0, :text)).to include("Visible finding")
    expect(listed.dig(:result, :content, 0, :text)).not_to include("Hidden finding")
    expect(read_visible.dig(:result, :content, 0, :text)).to include(
      "File visible work", "Remember visible context"
    )
    expect(read_hidden.dig(:result, :isError)).to be(true)
    expect(read_hidden.dig(:result, :content, 0, :text)).to include("not found or not accessible")
    expect(read_hidden.dig(:result, :content, 0, :text)).not_to include("Hidden finding")
    expect(forbidden_repository.dig(:result, :isError)).to be(true)
    expect(forbidden_repository.dig(:result, :content, 0, :text)).to include("repository not found or not accessible")
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
