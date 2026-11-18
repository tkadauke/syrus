require "rails_helper"

RSpec.describe ConnectedAccounts::AccountClient do
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
    expect { with_access(acting_mode: :as_owner) { :unused } }
      .to raise_error(described_class::Denied, /acting mode is not eligible/)
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
end
