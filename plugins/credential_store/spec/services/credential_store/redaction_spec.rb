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
end
