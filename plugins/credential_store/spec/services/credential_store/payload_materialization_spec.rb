require "rails_helper"

RSpec.describe CredentialStore::Broker, ".with_credential_payload" do
  let(:user) { Factories.user }
  let(:context) { McpToolContext.new(surface: :api, role: nil, user: user) }
  let(:credential) do
    CredentialStore::Credential.create!(
      name: "memory-only",
      credential_type: "connected_accounts.oauth",
      scope_type: "user",
      scope_id: user.id,
      created_by: user,
      owner_user: user,
      payload: "secret-payload",
      safe_metadata: {},
      target_constraints: {},
      allowed_surfaces: [ "api" ],
      allowed_tools: [ "connected_accounts.broker" ]
    )
  end

  it "materializes only in memory and records release after success" do
    result = described_class.with_credential_payload(
      context: context,
      credential: credential.id,
      type: "connected_accounts.oauth",
      purpose: "broker",
      tool_name: "connected_accounts.broker"
    ) { |payload, _metadata| "used #{payload}" }

    expect(result).to eq("used [credential redacted]")
    lease, release = CredentialStore::CredentialAccessEvent.where(credential: credential).order(:id).last(2)
    expect([ lease.action, release.action ]).to eq(%w[lease revoke])
    expect(release.completion_of_event).to eq(lease)
  end

  it "preserves broker errors raised while validating a payload" do
    expect {
      described_class.with_credential_payload(
        context: context,
        credential: credential.id,
        type: "connected_accounts.oauth",
        purpose: "broker",
        tool_name: "connected_accounts.broker"
      ) { raise described_class::InvalidPayload, "invalid payload" }
    }.to raise_error(described_class::InvalidPayload, "invalid payload")
  end

  it "redacts consumer-raised broker errors instead of trusting their messages" do
    [ described_class::Denied, described_class::NotFound ].each do |error_class|
      expect {
        described_class.with_credential_payload(
          context: context,
          credential: credential.id,
          type: "connected_accounts.oauth",
          purpose: "broker",
          tool_name: "connected_accounts.broker"
        ) { raise error_class, credential.payload }
      }.to raise_error(described_class::ExecutionError) { |error|
        expect(error.message).to include("[credential redacted]")
        expect(error.message).not_to include(credential.payload)
      }
    end
  end
end
