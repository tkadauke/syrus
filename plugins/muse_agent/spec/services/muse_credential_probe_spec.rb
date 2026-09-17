require "rails_helper"

RSpec.describe MuseCredentialProbe do
  before do
    PluginRecord.find_or_create_by!(name: "muse_agent").update!(enabled: true, default_enabled: false, disableable: true)
  end

  let(:user) { Factories.user(muse_api_key: "muse-secret") }

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

  it "is registered as the Muse credential probe" do
    expect(CredentialProbe.probe_handler_for("muse_api_key")).to eq(described_class)
  end

  it "reports a missing Muse key without spawning a process" do
    user.update!(muse_api_key: nil)
    expect(ProcessRunner).not_to receive(:new)

    result = CredentialProbe.call(user: user, credential: "muse_api_key")

    expect(result.ok).to be false
    expect(result.message).to eq("Muse API key is not configured.")
  end

  it "runs Muse with the stored key on stdin, not argv" do
    captured = nil
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured = kwargs
      instance_double(ProcessRunner, run: runner_result)
    end

    result = CredentialProbe.call(user: user, credential: "muse_api_key")

    expect(result.ok).to be true
    expect(result.message).to eq("Muse API key is valid.")
    expect(captured[:command]).to eq([ "muse", "exec", "--json", "--provider", "meta", "--api-key-stdin", "Reply with OK." ])
    expect(captured[:stdin_data]).to eq("muse-secret")
    expect(captured[:command].join(" ")).not_to include("muse-secret")
    expect(captured[:timeout]).to eq(30)
  end

  it "keeps the launcher pinned so the scrubbed env cannot re-enable its update check" do
    captured = nil
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured = kwargs
      instance_double(ProcessRunner, run: runner_result)
    end

    CredentialProbe.call(user: user, credential: "muse_api_key")

    expect(captured[:env]).to include("MUSE_NO_AUTO_UPDATE" => "1")
  end

  it "redacts failed CLI output through the plugin secret extractor" do
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      kwargs[:on_output_chunk].call("authentication failed for muse-secret\n")
      instance_double(ProcessRunner, run: runner_result(exit_status: 1))
    end

    result = CredentialProbe.call(user: user, credential: "muse_api_key")

    expect(result.ok).to be false
    expect(result.message).to include("authentication failed for [redacted]")
    expect(result.message).not_to include("muse-secret")
  end
end
