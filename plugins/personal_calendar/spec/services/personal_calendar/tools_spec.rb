require "rails_helper"

RSpec.describe "Personal Calendar concept tools" do
  let(:user) { Factories.user }
  let(:credential) do
    CredentialStore::Credential.create!(name: "calendar-spec", credential_type: "connected_accounts.oauth",
      scope_type: "user", scope_id: user.id, owner_user: user, created_by: user,
      payload: { access_token: "secret-token", expires_at: 5.minutes.from_now.iso8601 }.to_json,
      target_constraints: { "allowed_url_prefixes" => [ "https://example.test/" ] }, allowed_surfaces: [ "chat" ],
      allowed_tools: [ "connected_accounts.broker" ])
  end
  let(:account) do
    ConnectedAccounts::Account.create!(provider: "fake", display_label: "calendar@example.test", status: "connected",
      read_only: true, granted_scopes: [ "calendar.read" ], acting_modes: [ "as_self" ], owner_user: user,
      credential_store_credential: credential)
  end
  let(:context) { McpToolContext.new(surface: :chat, role: AgentRole::CHAT_PLANNER, user: user, permission_authorization: { tool_name: "personal_calendar_list_events" }) }
  let(:server_context) { { chat_session: instance_double(ChatSession) } }

  before do
    allow(McpToolContext).to receive(:from_server_context).and_return(context)
    allow(ConnectedAccounts::AccountClient).to receive(:with_access).and_yield(instance_double(ConnectedAccounts::Access))
    PersonalCalendar::FakeAdapter.events = [ { "id" => "e1", "title" => "Review", "description" => "<p>Outside text</p>" } ]
    provider = instance_double("provider", key: :fake)
    allow(provider).to receive(:invoke).and_yield(PersonalCalendar::FakeAdapter)
    allow(Syrus::PluginRegistry).to receive(:capability_providers).and_call_original
    allow(Syrus::PluginRegistry).to receive(:capability_providers).with(:personal_calendar, anything).and_return([ provider ])
  end
  after { PersonalCalendar::FakeAdapter.events = [] }

  it "lists and gets fake events with concept-level trust and markup shaping" do
    list = PersonalCalendar::ListEventsTool.call(account_id: account.id, acting_mode: "as_self",
      starts_at: "2026-01-01", ends_at: "2026-01-02", server_context:)
    payload = JSON.parse(list.content.first.fetch(:text))
    expect(payload).to include("trust" => "external_untrusted")
    expect(payload.dig("events", 0, "description")).to eq("Outside text")

    event = PersonalCalendar::GetEventTool.call(account_id: account.id, acting_mode: "as_self", event_id: "e1", server_context:)
    expect(JSON.parse(event.content.first.fetch(:text)).dig("event", "id")).to eq("e1")
    expect(event.content.to_s).not_to include("secret-token", "<p>")
  end

  it "registers account-scoped list/read descriptors" do
    descriptors = PersonalCalendar::PermissionProvider.permission_capability_descriptors
    expect(descriptors.map(&:operation)).to contain_exactly("personal_calendar.events/list@v1", "personal_calendar.event/read@v1")
    expect(descriptors.map { |descriptor| descriptor.resource_scope.type }).to all(eq(:connected_account))
    expect(descriptors).to all(have_attributes(risk: :medium))
  end

  it "moves oversized event descriptions and attachments to workspace files" do
    shaped = PersonalCalendar::ResultShaper.call({ "event" => { "id" => "large",
      "description" => "x" * (PersonalCalendar::ResultShaper::MAX_INLINE_BODY_BYTES + 1),
      "attachments" => [ { "filename" => "agenda.html", "content" => "<b>agenda</b>" } ] } }, context:)
    expect(shaped.fetch("event")).not_to have_key("description")
    expect(shaped.dig("event", "description_file")).to end_with("description.txt")
    expect(shaped.dig("event", "attachment_files", 0)).to end_with("agenda.html")
  end
end
