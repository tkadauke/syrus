require "rails_helper"

RSpec.describe ConnectedAccounts::AccountClient do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_with_run(user: user, repository: repository) }
  let(:run) { job.runs.first }
  let(:access_token) { "access-secret-12345" }
  let(:refresh_token) { "refresh-secret-67890" }
  let(:authorization) do
    { "tool_name" => "example.mail_search", "invocation_fingerprint" => "approved-fingerprint" }
  end

  def credential(owner: user, **attrs)
    CredentialStore::Credential.create!({
      name: "example-oauth-#{SecureRandom.hex(3)}",
      credential_type: "connected_accounts.oauth",
      scope_type: "user",
      scope_id: owner.id,
      created_by: owner,
      owner_user: owner,
      payload: {
        access_token: access_token,
        refresh_token: refresh_token,
        expires_at: 10.minutes.from_now.iso8601
      }.to_json,
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example.com/" ] },
      allowed_surfaces: [ "workflow" ],
      allowed_tools: [ described_class::BROKER_TOOL_NAME ]
    }.merge(attrs))
  end

  def account(owner: user, **attrs)
    ConnectedAccounts::Account.create!({
      provider_key: "example",
      display_label: "person@example.com",
      granted_scopes: %w[mail.read mail.write],
      access_ceiling: [ "mail.read" ],
      acting_modes: [ "as_self" ],
      status: "connected",
      owner_user: owner,
      credential: credential(owner: owner)
    }.merge(attrs))
  end

  def with_invocation(permission_authorization: authorization, run_record: run, &block)
    Mcp::Tools::AuthorizationSupport.with_server_context(
      { run: run_record, permission_authorization: permission_authorization },
      &block
    )
  end

  def call_client(record, **attrs, &block)
    described_class.with_access(
      account: record,
      acting_mode: attrs.fetch(:acting_mode, :as_self),
      scopes: attrs.fetch(:scopes, [ "mail.read" ]),
      purpose: attrs.fetch(:purpose, "search mail"),
      &block
    )
  end

  it "yields in-process access and revokes it when the block exits" do
    record = account
    yielded_access = nil
    observed_header = nil

    result = with_invocation do
      call_client(record) do |access|
        yielded_access = access
        observed_header = access.authorization_header
        { message: "completed" }
      end
    end

    expect(result).to eq(message: "completed")
    expect(observed_header).to eq("Bearer #{access_token}")
    expect(yielded_access).to be_revoked
    expect { yielded_access.authorization_header }
      .to raise_error(CredentialStore::Broker::Denied, "credential access denied: materialization lease revoked")
    expect(yielded_access.to_s).not_to include(access_token)
    expect(yielded_access.inspect).not_to include(access_token)
    expect(yielded_access.to_json).not_to include(access_token)
    expect(ENV.values).not_to include(access_token, refresh_token)
  end

  it "revokes access when the caller raises and redacts both OAuth tokens" do
    record = account
    yielded_access = nil

    expect {
      with_invocation do
        call_client(record) do |access|
          yielded_access = access
          raise "provider returned #{access_token} and #{refresh_token}"
        end
      end
    }.to raise_error(CredentialStore::Broker::ExecutionError) { |error|
      expect(error.message).not_to include(access_token, refresh_token)
      expect(error.message).to include(CredentialStore::Redaction::REDACTION)
    }
    expect(yielded_access).to be_revoked
  end

  it "redacts both tokens from successful tool results" do
    result = with_invocation do
      call_client(account) { { access: access_token, refresh: refresh_token } }
    end

    expect(result).to eq(
      access: CredentialStore::Redaction::REDACTION,
      refresh: CredentialStore::Redaction::REDACTION
    )
  end

  it "refuses an account owned by another user without revealing it" do
    other_user = Factories.user
    record = account(owner: other_user)

    expect { with_invocation { call_client(record) { true } } }
      .to raise_error(described_class::NotAccessible, "connected account is not accessible")
  end

  it "refuses an account that is not connected" do
    record = account(status: "needs_reauth")

    expect { with_invocation { call_client(record) { true } } }
      .to raise_error(CredentialStore::Broker::Denied, /account is not connected/)
  end

  it "refuses scopes outside the provider grant" do
    record = account

    expect { with_invocation { call_client(record, scopes: [ "calendar.read" ]) { true } } }
      .to raise_error(CredentialStore::Broker::Denied, /requested scopes exceed/)
  end

  it "refuses scopes outside the account ceiling" do
    record = account

    expect { with_invocation { call_client(record, scopes: [ "mail.write" ]) { true } } }
      .to raise_error(CredentialStore::Broker::Denied, /requested scopes exceed/)
  end

  it "refuses an ineligible acting mode" do
    record = account

    expect { with_invocation { call_client(record, acting_mode: :as_owner) { true } } }
      .to raise_error(CredentialStore::Broker::Denied, /acting mode is not eligible/)
  end

  it "refuses calls without an authorized invocation reference" do
    record = account

    expect { with_invocation(permission_authorization: {}) { call_client(record) { true } } }
      .to raise_error(described_class::UnauthorizedInvocation, /authorized tool invocation/)
  end

  it "records safe account and authorization audit content without tokens" do
    record = account

    with_invocation do
      call_client(record, purpose: "search mail using #{access_token}") { "ok" }
    end

    event = CredentialStore::CredentialAccessEvent.last
    expect(event).to have_attributes(
      credential: record.credential,
      user: user,
      run: run,
      tool_name: described_class::BROKER_TOOL_NAME,
      action: "lease",
      result: "allowed"
    )
    expect(event.metadata).to include(
      "provider" => "example",
      "account_id" => record.id,
      "acting_mode" => "as_self",
      "scopes" => [ "mail.read" ],
      "authorized_invocation" => authorization
    )
    expect(event.purpose).to include(CredentialStore::Redaction::REDACTION)
    expect(event.attributes.values.join(" ")).not_to include(access_token, refresh_token)
  end

  it "denies another plugin that calls the credential broker under its own tool name" do
    record = account
    context = McpToolContext.from_run(run)

    expect {
      CredentialStore::Broker.with_credential_value(
        context: context,
        credential: record.credential.id,
        type: "connected_accounts.oauth",
        purpose: "bypass broker",
        tool_name: "another_plugin.mail",
        target: { url: "https://api.example.com/" }
      ) { true }
    }.to raise_error(CredentialStore::Broker::Denied, /tool not allowed/)
  end
end
