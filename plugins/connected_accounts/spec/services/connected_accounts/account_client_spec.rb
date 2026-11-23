require "rails_helper"

RSpec.describe ConnectedAccounts::AccountClient do
  after { described_class.refresh_handler = nil }
  let(:owner) { Factories.user }
  let(:context) do
    McpToolContext.new(
      surface: :chat,
      role: AgentRole::CHAT_PLANNER,
      user: owner,
      permission_authorization: {
        "tool_name" => "mail_search",
        "invocation_fingerprint" => "authorized-reference"
      }
    )
  end
  let(:access_token) { "access-token-secret-123" }
  let(:refresh_token) { "refresh-token-secret-456" }
  let(:credential) do
    CredentialStore::Credential.create!(
      name: "example-oauth",
      credential_type: "connected_accounts.oauth",
      scope_type: "user",
      scope_id: owner.id,
      created_by: owner,
      owner_user: owner,
      payload: {
        access_token: access_token,
        refresh_token: refresh_token,
        expires_at: 5.minutes.from_now.iso8601
      }.to_json,
      safe_metadata: {},
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example.com/" ] },
      allowed_surfaces: [ "chat" ],
      allowed_tools: [ "connected_accounts.broker" ]
    )
  end
  let(:account) do
    ConnectedAccounts::Account.create!(
      provider: "example",
      display_label: "person@example.com",
      granted_scopes: %w[mail.read mail.send],
      status: "connected",
      read_only: false,
      acting_modes: %w[as_self],
      owner_user: owner,
      credential_store_credential: credential
    )
  end

  def with_access(**overrides, &block)
    described_class.with_access(
      account: account,
      acting_mode: :as_self,
      scopes: %w[mail.read],
      purpose: "Search the user's private mailbox for a password",
      context: context,
      target: { url: "https://api.example.com/messages" },
      **overrides,
      &block
    )
  end

  it "refuses an account owned by another user without revealing it" do
    other_context = McpToolContext.new(
      surface: :chat, role: AgentRole::CHAT_PLANNER, user: Factories.user,
      permission_authorization: { "tool_name" => "mail_search" }
    )

    expect { with_access(context: other_context) { :unused } }
      .to raise_error(described_class::Denied, "connected account not found")
  end

  it "refuses an account that is not connected" do
    account.update!(status: "needs_reauth")

    expect { with_access { :unused } }.to raise_error(described_class::Denied, /not connected/)
  end

  it "refuses scopes outside the grant" do
    expect { with_access(scopes: %w[drive.read]) { :unused } }
      .to raise_error(described_class::Denied, /exceed the account grant/)
  end

  it "refuses scopes outside a read-only ceiling" do
    account.update!(scope_ceiling: %w[mail.read])

    expect { with_access(scopes: %w[mail.send]) { :unused } }
      .to raise_error(described_class::Denied, /exceed the account ceiling/)
  end

  it "refuses an ineligible acting mode" do
    expect { with_access(acting_mode: :as_service) { :unused } }
      .to raise_error(described_class::Denied, /acting mode is not eligible/)
  end

  it "refuses as_owner by default and allows it only after the administrator opts in" do
    expect { with_access(acting_mode: :as_owner) { :unused } }
      .to raise_error(described_class::Denied, /acting as the account owner is disabled/)

    ConnectedAccounts::ProviderConfig.create!(provider_key: "example", authorize_url: "https://oauth.example/authorize",
      token_url: "https://oauth.example/token", identity_url: "https://api.example/me", client_id: "id", client_secret: "secret",
      scope_catalog: [], read_only_scopes: [], api_origins: [ "https://api.example/" ], allow_as_owner: true)
    expect(with_access(acting_mode: :as_owner) { :ok }).to eq(:ok)
  end

  it "blocks every coworker use while the feature gate is off" do
    coworker_context = McpToolContext.new(surface: :chat, role: AgentRole::COWORKER_CHAT, user: owner,
      permission_authorization: { "tool_name" => "mail_search" })
    allow(Feature).to receive(:coworker_connected_accounts_enabled?).and_return(false)

    expect { with_access(context: coworker_context) { :unused } }
      .to raise_error(described_class::Denied, /coworker connected account access is disabled/)
  end

  it "refuses access without an authorized invocation reference" do
    unauthorized = McpToolContext.new(surface: :chat, role: AgentRole::CHAT_PLANNER, user: owner)

    expect { with_access(context: unauthorized) { :unused } }
      .to raise_error(described_class::Denied, /authorized invocation reference is required/)
  end

  it "yields redacting access and scrubs both OAuth tokens from the result" do
    result = with_access do |access|
      expect(access.authorization_header).to eq("Bearer #{access_token}")
      expect(access.to_s).not_to include(access_token)
      expect(access.inspect).not_to include(access_token)
      expect(access.to_json).not_to include(access_token)

      { body: "#{access_token} and #{refresh_token}" }
    end

    expect(result.to_s).not_to include(access_token, refresh_token)
    expect(result[:body]).to eq("[credential redacted] and [credential redacted]")
  end

  it "records redacted audit metadata and releases the materialization lease" do
    with_access { :ok }

    lease, release = CredentialStore::CredentialAccessEvent.where(credential: credential).order(:id).last(2)
    expect(lease).to have_attributes(action: "lease", result: "allowed", purpose: "[purpose redacted]")
    expect(lease.metadata).to include(
      "provider" => "example",
      "connected_account_id" => account.id,
      "acting_mode" => "as_self",
      "scopes" => [ "mail.read" ],
      "purpose" => "[purpose redacted]",
      "authorized_invocation" => true
    )
    expect(release).to have_attributes(action: "revoke", result: "allowed", lease_id: nil)
    expect(release.completion_of_event).to eq(lease)
    expect([ lease, release ].map(&:attributes).to_s).not_to include(access_token, refresh_token)
  end

  it "releases the lease and redacts tokens when the block raises" do
    expect {
      with_access { raise "provider returned #{access_token} #{refresh_token}" }
    }.to raise_error(CredentialStore::Broker::ExecutionError) { |error|
      expect(error.message).not_to include(access_token, refresh_token)
    }

    events = CredentialStore::CredentialAccessEvent.where(credential: credential).order(:id)
    expect(events.pluck(:action)).to end_with("lease", "revoke")
    expect(events.last.completion_of_event).to eq(events[-2])
  end

  it "denies invalid OAuth payloads without misclassifying tool failures" do
    credential.update!(payload: "not-json")
    expect { with_access { :unused } }
      .to raise_error(described_class::Denied, "OAuth credential payload is invalid")

    credential.update!(payload: { refresh_token: refresh_token, expires_at: 5.minutes.from_now.iso8601 }.to_json)
    expect { with_access { :unused } }
      .to raise_error(described_class::Denied, "OAuth access token is unavailable")

    credential.update!(payload: {
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at: 5.minutes.from_now.iso8601
    }.to_json)
    expect {
      with_access { raise CredentialStore::Broker::InvalidPayload, access_token }
    }.to raise_error(CredentialStore::Broker::ExecutionError) { |error|
      expect(error.message).not_to include(access_token)
    }
  end

  it "atomically refreshes an expired token before yielding access" do
    expired_token = "expired-access-token"
    refreshed_token = "refreshed-access-token"
    credential.update!(payload: {
      access_token: expired_token,
      refresh_token: refresh_token,
      expires_at: 1.minute.ago.iso8601
    }.to_json)
    described_class.refresh_handler = lambda do |account:, tokens:|
      expect(account).to eq(self.account)
      expect(tokens).to include("access_token" => expired_token, "refresh_token" => refresh_token)
      tokens.merge("access_token" => refreshed_token, "expires_at" => 5.minutes.from_now.iso8601)
    end

    result = with_access do |access|
      expect(access.authorization_header).to eq("Bearer #{refreshed_token}")
      "#{expired_token} #{refresh_token} #{refreshed_token}"
    end

    expect(result).to eq("[credential redacted] [credential redacted] [credential redacted]")
    expect(credential.reload.access_events.pluck(:action)).to include("refresh")
  end

  it "fails closed when an expired token has no refresh handler" do
    credential.update!(payload: {
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at: 1.minute.ago.iso8601
    }.to_json)

    expect { with_access { :unused } }
      .to raise_error(described_class::Denied, "OAuth access token has expired")
  end

  it "rejects an expired refresh replacement without persisting it" do
    original_payload = {
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at: 1.minute.ago.iso8601
    }.to_json
    credential.update!(payload: original_payload)
    described_class.refresh_handler = lambda do |account:, tokens:|
      tokens.merge("access_token" => "still-expired", "expires_at" => 1.second.ago.iso8601)
    end

    expect { with_access { :unused } }
      .to raise_error(described_class::Denied, "refreshed OAuth access token is expired")
    expect(credential.reload.payload).to eq(original_payload)
  end

  it "denies another plugin that calls the credential broker under its own tool name" do
    expect {
      CredentialStore::Broker.with_credential_payload(
        context: context,
        credential: credential.id,
        type: "connected_accounts.oauth",
        purpose: "bypass",
        tool_name: "mail_plugin.direct",
        target: { url: "https://api.example.com/messages" }
      ) { :unused }
    }.to raise_error(CredentialStore::Broker::Denied, /tool not allowed/)
  end


  it "allows only declared system services to use instance-owned service accounts and audits their identity" do
    account
    credential.update!(scope_type: "instance", scope_id: nil, owner_user: nil, allowed_surfaces: [ "api" ])
    account.update!(owner_kind: "instance", owner_user: nil, acting_modes: [ "as_service" ])
    service = Class.new do
      class << self
        attr_reader :binding

        def register_system_access(_identity, binding) = (@binding = binding)
        def deliver(**options) = ConnectedAccounts::AccountClient.with_system_access(service_binding: binding, **options)
        def system_invoke(context) = { purpose: context.purpose, input: context.input }
      end
    end
    stub_const("CoreDeliveryService", service)
    stub_const("ConnectedAccounts::SystemInvocation::CORE_SERVICES", { "platform.delivery" => service }.freeze)
    ConnectedAccounts::SystemInvocation.send(:register_core_services!)
    declaration = instance_double(ConnectedAccounts::ProviderDeclaration)
    allow(ConnectedAccounts::ProviderRegistry).to receive(:fetch).with("example").and_return(declaration)

    result = service.deliver(account:, scopes: [ "mail.read" ], purpose: "deliver a platform notification",
      target: { url: "https://api.example.com/messages" }, input: { message_id: 7 })
    expect(result).to eq(purpose: "deliver a platform notification", input: { message_id: 7 })
    expect(credential.access_events.where(action: "lease").last.metadata).to include(
      "system_service_identity" => "platform.delivery", "acting_mode" => "as_service",
      "purpose" => "deliver a platform notification")

    expect {
      described_class.with_system_access(account:, service_binding: service.binding, scopes: [ "mail.read" ],
        purpose: "bypass", target: { url: "https://api.example.com/messages" }) { :caller_code }
    }.to raise_error(described_class::Denied, "system access does not accept caller code")

    expect {
      described_class.with_system_access(account:, service_binding: "platform.delivery", scopes: [ "mail.read" ],
        purpose: "bypass", target: { url: "https://api.example.com/messages" })
    }.to raise_error(described_class::Denied, "connected account not found")
  end


  it "allows a provider-declared system service without a core registration" do
    account
    credential.update!(scope_type: "instance", scope_id: nil, owner_user: nil, allowed_surfaces: [ "api" ])
    account.update!(owner_kind: "instance", owner_user: nil, acting_modes: [ "as_service" ])
    attributes = {
      provider: "ConnectedAccounts::FakeProvider", key: "example", display_name: "Example",
      capabilities: ConnectedAccounts::Provider::REQUIRED_CAPABILITIES,
      callback_route: "/unused", supports_read_only: false,
      system_service_identities: [ "provider.delivery" ],
      scopes: [ { key: "mail.read", label: "Read mail", risk: "low", syrus_capabilities: [ "mail.read@v1" ] } ]
    }
    allow(ConnectedAccounts::ProviderRegistry).to receive(:contributions).and_return([ [ "example_plugin", attributes ] ])
    ConnectedAccounts::ProviderRegistry.all

    result = ConnectedAccounts::FakeProvider.with_system_access(identity: "provider.delivery", account:,
      scopes: [ "mail.read" ], purpose: "deliver", target: { url: "https://api.example.com/messages" },
      input: { message_id: 7 })
    expect(result).to eq(authorization: "Bearer [credential redacted]", input: { message_id: 7 })

    stale_binding = ConnectedAccounts::FakeProvider.send(:system_access_bindings).fetch("provider.delivery")
    attributes[:system_service_identities] = []
    ConnectedAccounts::ProviderRegistry.all

    expect {
      described_class.with_system_access(account:, service_binding: stale_binding, scopes: [ "mail.read" ],
        purpose: "deliver", target: { url: "https://api.example.com/messages" })
    }.to raise_error(described_class::Denied, "connected account not found")
  end

  it "refuses the system path for user-owned accounts" do
    declaration = ConnectedAccounts::ProviderDeclaration.build(plugin_name: "example_plugin", attributes: {
      provider: "ConnectedAccounts::FakeProvider", key: "example", display_name: "Example",
      capabilities: ConnectedAccounts::Provider::REQUIRED_CAPABILITIES,
      callback_route: "/unused", supports_read_only: false,
      system_service_identities: [ "provider.delivery" ],
      scopes: [ { key: "mail.read", label: "Read mail", risk: "low", syrus_capabilities: [ "mail.read@v1" ] } ]
    })
    ConnectedAccounts::SystemInvocation.send(:register_provider!, declaration)
    allow(ConnectedAccounts::ProviderRegistry).to receive(:fetch).with("example").and_return(declaration)

    expect {
      ConnectedAccounts::FakeProvider.with_system_access(identity: "provider.delivery", account:,
        scopes: [ "mail.read" ], purpose: "bypass")
    }.to raise_error(described_class::Denied, "connected account not found")
  end
end
