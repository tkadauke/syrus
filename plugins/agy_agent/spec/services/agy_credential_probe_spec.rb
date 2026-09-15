require "rails_helper"

RSpec.describe AgyCredentialProbe do
  let(:user) { Factories.user(gemini_api_key: "AIza-secret") }

  def runner_result(exit_status: 0, timed_out: false, silent_timed_out: false)
    ProcessRunner::Result.new(
      exit_status: exit_status,
      timed_out: timed_out,
      stopped: false,
      silent_timed_out: silent_timed_out,
      operator_killed: false,
      aliveness_failed: false,
      duration_s: 0.1,
      spawned_process_id: nil
    )
  end

  it "is registered for the Antigravity readiness credential alias" do
    expect(CredentialProbe.probe_handler_for("agy")).to eq(described_class)
  end

  it "reports missing when the shared Gemini API key is absent" do
    user.update!(gemini_api_key: nil)

    result = CredentialProbe.call(user: user, credential: "agy")

    expect(result.ok).to be(false)
    expect(result.message).to include("no Gemini API key")
    expect(result.details).to include(status: "probe_unavailable")
  end

  it "runs a safe stream-json agy probe using the saved Gemini key" do
    captured = {}
    allow(ProcessRunner).to receive(:new) do |kwargs|
      captured = kwargs
      instance_double(ProcessRunner, run: runner_result)
    end

    result = CredentialProbe.call(user: user, credential: "agy")

    expect(result.ok).to be(true)
    expect(result.message).to eq("Antigravity accepted the shared Gemini API key.")
    expect(result.details).to include(shared_credential: "gemini_api_key")
    expect(captured[:command]).to include(
      "agy",
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--print=",
      "--print-timeout", "60s"
    )
    expect(captured[:stdin_data]).to include("\"event\":\"user\"")
    expect(captured[:env]).to include(
      "GEMINI_API_KEY" => "AIza-secret",
      "GOOGLE_API_KEY" => "AIza-secret"
    )
    expect(captured[:env]["HOME"]).to include("syrus-agy-probe")
  end

  it "classifies auth rejection without leaking the key" do
    allow(ProcessRunner).to receive(:new) do |kwargs|
      kwargs[:on_output_chunk].call("401 unauthorized for AIza-secret\n")
      instance_double(ProcessRunner, run: runner_result(exit_status: 1))
    end

    result = CredentialProbe.call(user: user, credential: "agy")

    expect(result.ok).to be(false)
    expect(result.details).to include(status: "auth_error")
    expect(result.message).to include("[redacted]")
    expect(result.message).not_to include("AIza-secret")
  end

  it "reports timeout/network/process failures as inconclusive" do
    allow(ProcessRunner).to receive(:new) do |kwargs|
      kwargs[:on_output_chunk].call("network unreachable\n")
      instance_double(ProcessRunner, run: runner_result(timed_out: true))
    end

    result = CredentialProbe.call(user: user, credential: "agy")

    expect(result.ok).to be(false)
    expect(result.details).to include(status: "probe_inconclusive")
    expect(result.message).to include("timed out")
  end

  it "records provider availability evidence from refresh_for" do
    allow(ProcessRunner).to receive(:new).and_return(instance_double(ProcessRunner, run: runner_result))

    expect {
      result = described_class.refresh_for(user: user, force: true)
      expect(result.ok).to be(true)
    }.to change(ProviderAvailabilityEvidence.where(provider: "agy", status: "available"), :count).by(1)
  end
end
