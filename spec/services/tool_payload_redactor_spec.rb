require "rails_helper"

RSpec.describe ToolPayloadRedactor do
  it "redacts sensitive keys and inline secrets like chat tool cards" do
    payload = {
      "apiKey" => "secret-value",
      "nested" => { "password" => "hunter2", "message" => "token=visible-secret" },
      "credential_mode" => "pat"
    }

    expect(described_class.redact(payload)).to eq(
      "apiKey" => "[redacted]",
      "nested" => { "password" => "[redacted]", "message" => "token=[redacted]" },
      "credential_mode" => "pat"
    )
  end

  it "redacts free-form credentials with the chat tool-card policy" do
    private_key = "-----BEGIN PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----"
    payload = {
      "authorization" => "metadata secret",
      "output" => [
        "Authorization: Bearer abcdefghijklmnop",
        private_key,
        "provider token sk-abcdefghijklmnopqrstuvwxyz",
        "curl -u deploy:password-value https://example.test",
        "https://deploy:password-value@example.test/path"
      ]
    }

    expect(described_class.redact(payload)).to eq(
      "authorization" => "[redacted]",
      "output" => [
        "Authorization: Bearer [redacted]",
        "[redacted]",
        "provider token [redacted]",
        "curl -u deploy:[redacted] https://example.test",
        "https://deploy:[redacted]@example.test/path"
      ]
    )
  end

  it "preserves safe identifier and secret-resource metadata like chat tool cards" do
    payload = {
      "name" => "token-service",
      "credential" => { "credential_id" => 7, "credential_name" => "deploy-token", "value" => "secret" },
      "secret" => { "name" => "api-token", "namespace" => "production", "data" => "secret" }
    }

    expect(described_class.redact(payload)).to eq(
      "name" => "token-service",
      "credential" => { "credential_id" => 7, "credential_name" => "deploy-token", "value" => "[redacted]" },
      "secret" => { "name" => "api-token", "namespace" => "production", "data" => "[redacted]" }
    )
  end
end
