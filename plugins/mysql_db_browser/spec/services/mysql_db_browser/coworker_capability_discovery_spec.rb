require "rails_helper"

# End to end: a coworker discovers mysql.read, learns why it is blocked, asks
# for access when only permission is missing, and gets owner remediation when
# infrastructure or configuration is the blocker.
RSpec.describe "coworker MySQL capability discovery" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: user, name: "Adrian", handle: "adrian-discovery",
      workspace_repo: repository.remote_url)
  end
  let(:confined) { { available: true, reason: nil } }

  before do
    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat_session, role: "main")
    owner_coworker = coworker
    chat_session.define_singleton_method(:coworker) { owner_coworker }
    availability = confined
    chat_session.define_singleton_method(:coworker_grant_availability) { |_name| availability }
  end

  def connection!(**attributes)
    Factories.mysql_connection(agentic_access_enabled: true, **attributes).tap do |connection|
      MysqlDbBrowser::CredentialMaterial.store!(connection, "secret", user: user, scope_type: "user", scope_id: user.id)
    end
  end

  def server_context = { chat_session: chat_session }

  def discover(**arguments)
    response = Mcp::Tools::DiscoverCoworkerCapabilitiesTool.call(server_context:, include_non_requestable: true, **arguments)
    JSON.parse(response.content.first[:text], symbolize_names: true).fetch(:capabilities)
      .find { |entry| entry[:capability] == "mysql.read" }
  end

  it "makes a missing grant requestable with a valid request_permission payload" do
    connection = connection!

    entry = discover

    expect(entry).to include(state: "requestable", lock_reason: "capability_not_granted", blocker: "permission")
    expect(entry[:permitted_scope][:options]).to include(a_hash_including(value: connection.id))
    action = entry.fetch(:next_action)
    expect(action).to include(type: "request_permission", grants_authority: false)
    request = action.fetch(:requests).first
    expect(request).to include(capability: "mysql.read@v1", resource_scope: { mysql_connection_id: connection.id })

    response = Mcp::Tools::RequestPermissionTool.call(server_context:, **request.slice(:capability, :operation, :resource_scope),
      purpose: "Check the orders schema")
    body = JSON.parse(response.content.first[:text], symbolize_names: true)
    expect(response.error?).to be(false)
    expect(body).to include(status: "created", grants_authority: false)
    expect(entry.dig(:next_action, :resume, :tools)).to include("mysql_db_browser_list_connections")
  end

  it "reports a failed confinement probe as infrastructure, not a permission problem" do
    connection = connection!
    coworker.grants.create!(capability: "mysql.read", approval_policy: "confirm", scope: connection.id)
    allow(chat_session).to receive(:coworker_grant_availability).and_return({ available: false, reason: "confinement_probe_failed" })

    entry = discover

    expect(entry).to include(state: "unavailable", lock_reason: "confinement_probe_failed", blocker: "infrastructure")
    expect(entry[:prerequisites]).to include(a_hash_including(id: "confinement", satisfied: false))
    expect(entry.fetch(:next_action)).to include(type: "owner_remediation", grant_alone_sufficient: false)
    expect(entry[:next_action][:message]).to include("probe")
    expect(entry[:next_action]).not_to have_key(:requests)
  end

  it "reports a missing agentic-access connection with owner remediation" do
    MysqlConnection.destroy_all
    Factories.mysql_connection(agentic_access_enabled: false)

    entry = discover

    expect(entry).to include(state: "resource_unconfigured", blocker: "resource")
    expect(entry.dig(:next_action, :type)).to eq("owner_remediation")
    expect(entry.dig(:next_action, :message)).to include("agentic access")
  end

  it "keeps the capability visible when the plugin is disabled" do
    connection!
    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    entry = discover

    expect(entry).to include(state: "plugin_disabled", blocker: "plugin")
    expect(entry.dig(:next_action, :type)).to eq("owner_remediation")
  end

  it "hides blocked entries unless include_non_requestable is set" do
    connection!
    allow(chat_session).to receive(:coworker_grant_availability).and_return({ available: false, reason: "confinement_probe_missing" })

    response = Mcp::Tools::DiscoverCoworkerCapabilitiesTool.call(server_context:)

    names = JSON.parse(response.content.first[:text], symbolize_names: true).fetch(:capabilities).map { |entry| entry[:capability] }
    expect(names).not_to include("mysql.read")
  end

  it "returns a machine-readable next action with not_authorized for a blocked tool" do
    connection!
    context = McpToolContext.from_chat_session(chat_session)

    response = Mcp::Tools.not_authorized_for(context, "mysql_db_browser_list_connections")

    body = JSON.parse(response.content.first[:text], symbolize_names: true)
    expect(body).to include(error: "not_authorized", capability: "mysql.read", state: "requestable",
      blocker: "permission")
    expect(body.dig(:next_action, :type)).to eq("request_permission")
  end

  it "never creates a grant while discovering" do
    connection!
    expect { discover }.not_to change { coworker.grants.count }
  end
end
