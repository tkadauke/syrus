require "rails_helper"

RSpec.describe "Mail concept tools" do
  let(:user) { Factories.user }
  let(:credential) do
    CredentialStore::Credential.create!(name: "mail-spec", credential_type: "connected_accounts.oauth",
      scope_type: "user", scope_id: user.id, owner_user: user, created_by: user,
      payload: { access_token: "secret-token", expires_at: 5.minutes.from_now.iso8601 }.to_json,
      target_constraints: { "allowed_url_prefixes" => [ "https://example.test/" ] }, allowed_surfaces: [ "chat" ],
      allowed_tools: [ "connected_accounts.broker" ])
  end
  let(:account) do
    ConnectedAccounts::Account.create!(provider: "fake", display_label: "mail@example.test", status: "connected",
      read_only: true, granted_scopes: [ "mail.read" ], acting_modes: [ "as_self" ], owner_user: user,
      credential_store_credential: credential)
  end
  let(:context) do
    McpToolContext.new(surface: :chat, role: AgentRole::CHAT_PLANNER, user: user,
      permission_authorization: { tool_name: "mail_search", invocation_fingerprint: "reference" })
  end
  let(:server_context) { { chat_session: instance_double(ChatSession), permission_authorization: context.permission_authorization } }

  before do
    allow(McpToolContext).to receive(:from_server_context).and_return(context)
    allow(ConnectedAccounts::AccountClient).to receive(:with_access).and_yield(instance_double(ConnectedAccounts::Access))
    SyrusMail::FakeAdapter.messages = [ { "id" => "m1", "subject" => "Project update", "body" => "<b>Hello</b>",
      "attachments" => [ { "filename" => "note.txt", "content" => "attachment" } ] } ]
  end

  after { SyrusMail::FakeAdapter.messages = [] }

  it "searches and reads through the fake adapter with trust shaping and no tokens" do
    allow(Syrus::PluginRegistry).to receive(:capability_providers).and_call_original
    provider = instance_double("provider", key: :fake)
    allow(provider).to receive(:invoke).and_yield(SyrusMail::FakeAdapter)
    allow(Syrus::PluginRegistry).to receive(:capability_providers).with(:mail, anything).and_return([ provider ])

    search = SyrusMail::SearchTool.call(account_id: account.id, acting_mode: "as_self", query: "project", server_context:)
    search_payload = JSON.parse(search.content.first.fetch(:text))
    expect(search_payload).to include("trust" => "external_untrusted")
    expect(search_payload.dig("messages", 0, "subject")).to eq("Project update")

    read = SyrusMail::ReadMessageTool.call(account_id: account.id, acting_mode: "as_self", message_id: "m1", server_context:)
    payload = JSON.parse(read.content.first.fetch(:text))
    expect(payload).to include("trust" => "external_untrusted", "body" => "Hello")
    expect(payload.fetch("attachment_files").first).to end_with("note.txt")
    expect(read.content.to_s).not_to include("secret-token", "<b>")
  end

  it "refuses disconnected accounts, excessive scopes, and disabled coworker access" do
    [ "account is not connected", "requested scopes exceed the account grant", "coworker connected account access is disabled" ].each do |message|
      allow(ConnectedAccounts::AccountClient).to receive(:with_access)
        .and_raise(ConnectedAccounts::AccountClient::Denied, message)
      response = SyrusMail::SearchTool.call(account_id: account.id, acting_mode: "as_self", query: "x", server_context:)
      expect(response.content.first.fetch(:text)).to include(message)
    end
  end

  it "moves oversized message bodies to workspace files" do
    shaped = SyrusMail::ResultShaper.call({ "id" => "large", "body" => "x" * (SyrusMail::ResultShaper::MAX_INLINE_BODY_BYTES + 1) }, context:)
    expect(shaped).not_to have_key("body")
    expect(shaped.fetch("body_file")).to end_with("body.txt")
    expect(shaped).to include("trust" => "external_untrusted")
  end

  it "keeps metadata-only attachments in context without creating empty files" do
    attachment = { "filename" => "invoice.pdf", "content_type" => "application/pdf", "size" => 4312 }
    shaped = SyrusMail::ResultShaper.call({ "id" => "metadata", "attachments" => [ attachment ] }, context:)

    expect(shaped.fetch("attachments")).to eq([ attachment ])
    expect(shaped).not_to have_key("attachment_files")
  end

  it "registers account-scoped read/search descriptors" do
    descriptors = SyrusMail::PermissionProvider.permission_capability_descriptors
    expect(descriptors.map(&:operation)).to contain_exactly("mail/search@v1", "mail.message/read@v1")
    expect(descriptors.map { |descriptor| descriptor.resource_scope.type }).to all(eq(:connected_account))
    expect(descriptors).to all(have_attributes(risk: :medium))
  end

  it "redacts search queries without adding a query to read-message audits" do
    search = SyrusMail::PermissionProvider.capability_descriptor("mail/search@v1")
    read = SyrusMail::PermissionProvider.capability_descriptor("mail.message/read@v1")

    expect(search.redact(query: "private terms")).to include("query" => "[REDACTED]")
    expect(read.redact(message_id: "m1")).to eq("message_id" => "m1", "provenance" => "external_untrusted")
  end
end
