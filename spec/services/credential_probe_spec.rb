require "rails_helper"

RSpec.describe CredentialProbe do
  let(:user) do
    Factories.user(
      github_token: "ghp_secret",
      claude_oauth_token: "oat-secret",
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

  it "validates a GitHub token and reports login plus scopes" do
    stub_request(:get, "https://api.github.com/user")
      .with(headers: { "Authorization" => "token ghp_secret" })
      .to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json",
          "x-oauth-scopes" => "repo, workflow",
          "x-accepted-oauth-scopes" => "user"
        },
        body: { login: "ada" }.to_json
      )

    result = described_class.call(user: user, credential: "github_token")

    expect(result.ok).to be true
    expect(result.message).to eq("GitHub token is valid for ada.")
    expect(result.details).to include(
      login: "ada",
      scopes: %w[ repo workflow ],
      accepted_scopes: [ "user" ]
    )
  end

  it "reports a missing Claude token without spawning a process" do
    user.update!(claude_oauth_token: nil)
    expect(ProcessRunner).not_to receive(:new)

    result = described_class.call(user: user, credential: "claude_oauth_token")

    expect(result.ok).to be false
    expect(result.message).to eq("Claude OAuth token is not configured.")
  end

  it "runs a cheap Claude CLI probe with the stored OAuth token" do
    captured = nil
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured = kwargs
      instance_double(ProcessRunner, run: runner_result)
    end

    result = described_class.call(user: user, credential: "claude_oauth_token")

    expect(result.ok).to be true
    expect(result.message).to eq("Claude OAuth token is valid.")
    expect(captured[:env]).to include("CLAUDE_CODE_OAUTH_TOKEN" => "oat-secret")
    expect(captured[:command]).to include("claude", "--print", "--max-turns", "1")
    expect(captured[:timeout]).to eq(30)
  end

  it "redacts failed CLI output" do
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      kwargs[:on_output_chunk].call("authentication failed for oat-secret\n")
      instance_double(ProcessRunner, run: runner_result(exit_status: 1))
    end

    result = described_class.call(user: user, credential: "claude_oauth_token")

    expect(result.ok).to be false
    expect(result.message).to include("authentication failed for [redacted]")
    expect(result.message).not_to include("oat-secret")
  end

  it "rejects Codex API key tests when Codex is in ChatGPT auth mode" do
    user.update!(codex_auth_mode: "chatgpt_login", codex_auth_json: Factories.codex_auth_json)

    result = described_class.call(user: user, credential: "codex_api_key")

    expect(result.ok).to be false
    expect(result.message).to eq("Codex is set to ChatGPT auth.json mode.")
  end

  it "runs a Codex CLI probe with the stored API key" do
    captured = nil
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured = kwargs
      instance_double(ProcessRunner, run: runner_result)
    end

    result = described_class.call(user: user, credential: "codex_api_key")

    expect(result.ok).to be true
    expect(result.message).to eq("Codex credentials are valid.")
    expect(captured[:env]).to include("CODEX_API_KEY" => "sk-codex-secret")
    expect(captured[:command]).to include("codex", "exec", "--json")
  end
end
