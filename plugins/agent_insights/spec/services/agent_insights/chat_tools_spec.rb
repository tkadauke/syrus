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
    Coworkers::Coworker.create!(
      owner_user: user, name: "Insight reader", handle: "insight-reader", workspace_repo: repository.remote_url
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

  def allow_insight_reads!(actor: coworker)
    %w[list_insights read_insight].each do |capability|
      actor.permission_rules.update!(capability: capability, approval_policy: "auto", actor: actor.owner_user)
    end
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

  it "inherits every ordinary insight chat tool for coworkers on the deferred tier" do
    enable!(true)

    essential_names = described_class.chat_tools(chat_session, tier: :essential, agent_actor: coworker)
      .map { |tool| McpToolRegistry.tool_name_for(tool) }
    deferred_names = described_class.chat_tools(chat_session, tier: :deferred, agent_actor: coworker)
      .map { |tool| McpToolRegistry.tool_name_for(tool) }

    expect(essential_names).not_to include("list_insights", "read_insight")
    expect(deferred_names).to include(
      "list_insights", "read_insight", "accept_insight", "dismiss_insight", "retire_insight"
    )
    expect(deferred_names).not_to include("submit_insight", "update_insight")
  end

  it "classifies every ordinary insight chat tool in the coworker catalog" do
    enable!(true)
    allow(McpToolContext).to receive(:from_chat_session).with(chat_session).and_return(
      instance_double(McpToolContext, role: AgentRole::COWORKER_CHAT)
    )

    names = AgentInsights::ChatToolSet::TOOL_CLASSES.map(&:tool_name)
    descriptors = Mcp::CoworkerToolCatalog.all(chat_session: chat_session)
      .select { |descriptor| names.include?(descriptor.tool_name) }

    expect(descriptors.map(&:tool_name).uniq).to contain_exactly(*names)
    expect(descriptors).to all(have_attributes(tier: :deferred, ungated: false, availability_state: :available))
  end

  it "keeps coworker reads scoped to attached repositories without leaking inaccessible insights" do
    enable!(true)
    allow_insight_reads!
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

  it "does not grant an admin owner's global insight access to their coworker" do
    enable!(true)
    admin = Factories.user(admin: true)
    admin_repository = Factories.repository(user: admin)
    admin_chat = ChatSession.create!(user: admin, repository: admin_repository)
    admin_coworker = Coworkers::Coworker.create!(
      owner_user: admin, name: "Admin insight reader", handle: "admin-insight-reader",
      workspace_repo: admin_repository.remote_url
    )
    allow_insight_reads!(actor: admin_coworker)
    visible_job = Job.create!(user: admin, repository: admin_repository, kind: "agent_insight", priority: "low")
    visible = AgentInsights::Suggestion.create!(
      job: visible_job, repository: admin_repository, title: "Attached admin finding",
      category: "configuration", severity: "low", confidence: 0.5
    )
    hidden_repository = Factories.repository(user: Factories.user)
    hidden_job = Job.create!(user: hidden_repository.user, repository: hidden_repository, kind: "agent_insight", priority: "low")
    hidden = AgentInsights::Suggestion.create!(
      job: hidden_job, repository: hidden_repository, title: "Global admin finding",
      category: "secret", severity: "low", confidence: 0.5
    )
    server = server_for(admin_chat, tier: :deferred, agent_actor: admin_coworker)
    _ = jsonrpc(server, "initialize", id: 0)

    listed = call_tool(server, "list_insights")
    read_visible = call_tool(server, "read_insight", id: visible.id)
    read_hidden = call_tool(server, "read_insight", id: hidden.id)
    forbidden_repository = call_tool(server, "list_insights", repository_id: hidden_repository.id)

    expect(listed.dig(:result, :content, 0, :text)).to include("Attached admin finding")
    expect(listed.dig(:result, :content, 0, :text)).not_to include("Global admin finding")
    expect(read_visible.dig(:result, :isError)).to be_falsey
    expect(read_hidden.dig(:result, :isError)).to be(true)
    expect(read_hidden.dig(:result, :content, 0, :text)).to include("not found or not accessible")
    expect(read_hidden.dig(:result, :content, 0, :text)).not_to include("Global admin finding")
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
