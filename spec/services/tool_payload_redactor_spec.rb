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
end
