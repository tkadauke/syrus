require "rails_helper"

RSpec.describe CredentialStore::Redaction do
  it "scrubs known payloads and unsafe probe-shaped output" do
    text = <<~TEXT
      token: abc12345
      Authorization: Bearer bearer-token
      -----BEGIN PRIVATE KEY-----
      raw-key-material
      -----END PRIVATE KEY-----
      exact-secret
    TEXT

    scrubbed = described_class.scrub(text, extra_secrets: [ "exact-secret" ])

    expect(scrubbed).to include(CredentialStore::Redaction::REDACTION)
    expect(scrubbed).not_to include("abc12345")
    expect(scrubbed).not_to include("bearer-token")
    expect(scrubbed).not_to include("raw-key-material")
    expect(scrubbed).not_to include("exact-secret")
  end

  it "scrubs MCP tool response content, structured content, and metadata" do
    response = MCP::Tool::Response.new(
      [ { type: "text", text: "exact-secret" } ],
      error: true,
      structured_content: { token: "exact-secret" },
      meta: { token: "exact-secret" }
    )

    scrubbed = described_class.scrub_object(response, extra_secrets: [ "exact-secret" ])

    expect(scrubbed).to be_a(MCP::Tool::Response)
    expect(scrubbed).to be_error
    expect(scrubbed.content).to eq([ { type: "text", text: CredentialStore::Redaction::REDACTION } ])
    expect(scrubbed.structured_content).to eq(token: CredentialStore::Redaction::REDACTION)
    expect(scrubbed.meta).to eq(token: CredentialStore::Redaction::REDACTION)
  end
end
