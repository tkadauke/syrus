require "rails_helper"

RSpec.describe ConnectedAccounts::AccountClient do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:job) { Factories.job_with_run(user: owner, repository:) }
  let(:run) { job.runs.first }
  let(:authorization) { { "tool_name" => "mail.search", "invocation_fingerprint" => "authorized-fingerprint" } }
  let(:context) do
    McpToolContext.new(
      surface: :run, role: "implement", user: owner, repository:, job:,
      workflow: run.workflow, run:, permission_authorization: authorization
    )
  end
  let(:access_token) { "access-secret-12345" }
  let(:refresh_token) { "refresh-secret-67890" }
  let(:credential) do
    CredentialStore::Credential.create!(
      name: "example-oauth", credential_type: "connected_accounts.oauth",
      scope_type: "user", scope_id: owner.id, created_by: owner, owner_user: owner,
      payload: { access_token:, refresh_token:, expires_at: 10.minutes.from_now.iso8601 }.to_json,
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example.com/" ] },
      allowed_surfaces: [ "workflow" ], allowed_tools: [ described_class::TOOL_NAME ]
    )
  end
  let(:account) do
    ConnectedAccounts::Account.create!(
      owner_user: owner, credential:, provider_key: "example", display_label: "owner@example.com",
      granted_scopes: %w[mail.read mail.send], scope_ceiling: %w[mail.read],
      acting_modes: %w[as_self], status: "connected"
    )
  end

  before { described_class.token_refresher = nil }
  after { described_class.token_refresher = nil }

  def call(account_ref: account, call_context: context, mode: :as_self, scopes: %w[mail.read], purpose: "search mail", &block)
    described_class.with_access(
      account: account_ref, acting_mode: mode, scopes:, purpose:, context: call_context,
      target: { url: "https://api.example.com/messages" }, &block
    )
  end

  it "refuses an account owned by another user before leasing" do
    other = Factories.user
    foreign_context = McpToolContext.new(surface: :run, role: "implement", user: other, permission_authorization: authorization)

    expect { call(call_context: foreign_context) { :unused } }.to raise_error(described_class::Denied, /another user/)
    expect(CredentialStore::CredentialAccessEvent.where(action: "lease")).to be_empty
  end

  it "refuses accounts that are not connected" do
    account.update!(status: "needs_reauth")

    expect { call { :unused } }.to raise_error(described_class::Denied, /not connected/)
  end

  it "refuses scopes outside the grant" do
    expect { call(scopes: %w[calendar.read]) { :unused } }.to raise_error(described_class::Denied, /grant or ceiling/)
  end

  it "refuses scopes outside the ceiling" do
    expect { call(scopes: %w[mail.send]) { :unused } }.to raise_error(described_class::Denied, /grant or ceiling/)
  end

  it "refuses an ineligible acting mode through the credential validator" do
    expect { call(mode: :as_owner) { :unused } }.to raise_error(described_class::Denied, /acting mode/)
    expect(CredentialStore::CredentialAccessEvent.last).to have_attributes(result: "denied", denial_reason: "acting mode is not eligible for this account")
  end

  it "refuses calls without an authorized invocation reference" do
    unauthorized = McpToolContext.new(surface: :run, role: "implement", user: owner)

    expect { call(call_context: unauthorized) { :unused } }.to raise_error(described_class::Denied, /authorized invocation/)
  end

  it "yields redacting access, scrubs both tokens, audits safe metadata, and closes the lease" do
    observed = nil
    result = call(purpose: "  search   private mail #{access_token}  ") do |access|
      observed = access
      {
        header: access.authorization_header,
        access_token:, refresh_token:,
        access_string: access.to_s, inspected: access.inspect
      }
    end

    expect(observed.to_s).not_to include(access_token)
    expect(observed.inspect).not_to include(access_token)
    expect(result).to include(
      header: "Bearer [credential redacted]",
      access_token: "[credential redacted]", refresh_token: "[credential redacted]"
    )
    lease = CredentialStore::CredentialAccessEvent.find_by!(action: "lease")
    completion = CredentialStore::CredentialAccessEvent.find_by!(completion_of_event: lease)
    expect(completion).to have_attributes(action: "use", result: "allowed")
    expect(lease.metadata).to include(
      "provider" => "example", "connected_account_id" => account.id,
      "acting_mode" => "as_self", "scopes" => [ "mail.read" ], "purpose" => "search private mail [credential redacted]"
    )
    expect([ lease, completion ].flat_map { |event| event.attributes.values }.join(" ")).not_to include(access_token, refresh_token)
  end

  it "closes the lease and redacts token-bearing exceptions" do
    expect {
      call { raise "provider leaked #{access_token} and #{refresh_token}" }
    }.to raise_error(described_class::Denied, /credential redacted/)

    lease = CredentialStore::CredentialAccessEvent.find_by!(action: "lease")
    expect(CredentialStore::CredentialAccessEvent.find_by!(completion_of_event: lease)).to have_attributes(result: "failed")
  end

  it "refreshes expired payloads through the locked plugin refresh operation" do
    credential.update!(payload: { access_token:, refresh_token:, expires_at: 1.minute.ago.iso8601 }.to_json)
    described_class.token_refresher = lambda do |account:, payload:|
      expect(account).to eq(self.account)
      expect(payload["refresh_token"]).to eq(refresh_token)
      { access_token: "replacement-access", refresh_token: "replacement-refresh", expires_at: 1.hour.from_now.iso8601 }
    end

    result = call { |access| access.authorization_header }

    expect(result).to eq("Bearer [credential redacted]")
    expect(credential.access_events.where(action: "refresh")).to exist
  end

  it "prevents another plugin from leasing the credential under its own tool name" do
    expect {
      CredentialStore::Broker.with_credential(
        context:, credential: credential.id, type: described_class::CREDENTIAL_TYPE,
        purpose: "bypass", tool_name: "mail.direct", target: { url: "https://api.example.com/messages" }
      ) { :unused }
    }.to raise_error(CredentialStore::Broker::Denied, /typed consumer/)
  end

  it "does not materialize tokens in files, environments, or process arguments" do
    expect(Tempfile).not_to receive(:new)
    expect(Process).not_to receive(:spawn)
    expect(ENV.to_h.values.join(" ")).not_to include(access_token, refresh_token)

    call { |access| access.authorization_header }
  end
end
