require "rails_helper"

RSpec.describe "internal CLI secret redaction" do
  it "redacts invocation contexts and credential lease identifiers from command text" do
    text = "SYRUS_CLI_INVOCATION_CONTEXT=signed-token credential_lease_id=lease-secret"

    expect(CommandRedactor.redact(text)).to eq(
      "SYRUS_CLI_INVOCATION_CONTEXT=[REDACTED] credential_lease_id=[REDACTED]"
    )
  end

  it "redacts invocation contexts and lease identifiers from operational log values" do
    text = "invocation_context=signed-token lease_id=lease-secret"

    expect(OperationalLogging.redact(text)).to eq(
      "invocation_context=[REDACTED] lease_id=[REDACTED]"
    )
  end
end
