require "rails_helper"

RSpec.describe CodexCredentialProbe do
  let(:user) do
    Factories.user(
      github_token: "ghp_secret",
      codex_api_key: "sk-codex-secret",
      codex_auth_mode: "api_key"
    )
  end

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

  it "is registered as the handler for Codex credentials" do
    expect(CredentialProbe.probe_handler_for("codex_api_key")).to eq(described_class)
    expect(CredentialProbe.probe_handler_for("codex_auth_json")).to eq(described_class)
  end

  it "rejects Codex API key tests when Codex is in ChatGPT auth mode" do
    user.update!(codex_auth_mode: "chatgpt_login", codex_auth_json: Factories.codex_auth_json)

    result = CredentialProbe.call(user: user, credential: "codex_api_key")

    expect(result.ok).to be false
    expect(result.message).to eq("Codex is set to ChatGPT auth.json mode.")
  end

  it "runs a Codex CLI probe with the stored API key" do
    captured = nil
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured = kwargs
      instance_double(ProcessRunner, run: runner_result)
    end

    result = CredentialProbe.call(user: user, credential: "codex_api_key")

    expect(result.ok).to be true
    expect(result.message).to eq("Codex credentials are valid.")
    expect(captured[:env]).to include("CODEX_API_KEY" => "sk-codex-secret")
    expect(captured[:command]).to include("codex", "exec", "--json")
  end

  describe "codex_auth_json credential" do
    let(:auth_json) { Factories.codex_auth_json(access_token: "access-test") }
    let(:user) do
      Factories.user(codex_auth_mode: "chatgpt_login", codex_auth_json: auth_json)
    end

    it "rejects codex_auth_json tests when Codex is in API key mode" do
      user.update!(codex_auth_mode: "api_key", codex_api_key: "sk-test", codex_auth_json: auth_json)

      result = CredentialProbe.call(user: user, credential: "codex_auth_json")

      expect(result.ok).to be false
      expect(result.message).to eq("Codex is set to API key mode.")
    end

    it "reports missing auth.json when not configured" do
      user.update!(codex_auth_json: nil)

      result = CredentialProbe.call(user: user, credential: "codex_auth_json")

      expect(result.ok).to be false
      expect(result.message).to eq("Codex ChatGPT auth.json is not configured.")
    end

    it "redacts Codex API keys and auth token values through the plugin secret extractor" do
      user.update!(codex_api_key: "sk-secret", codex_auth_json: Factories.codex_auth_json(access_token: "access-secret"))
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        kwargs[:on_output_chunk].call("bad sk-secret access-secret")
        instance_double(ProcessRunner, run: runner_result(exit_status: 1))
      end

      result = CredentialProbe.call(user: user, credential: "codex_auth_json")

      expect(result.message).to include(CredentialProbe::REDACTED)
      expect(result.message).not_to include("sk-secret")
      expect(result.message).not_to include("access-secret")
    end
  end
end
