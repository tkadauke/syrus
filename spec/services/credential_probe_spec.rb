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

  describe ".github_token" do
    def stub_user(token, scopes:, status: 200, login: "ada")
      stub_request(:get, "https://api.github.com/user")
        .with(headers: { "Authorization" => "token #{token}" })
        .to_return(
          status: status,
          headers: { "Content-Type" => "application/json", "x-oauth-scopes" => scopes },
          body: { login: login }.to_json
        )
    end

    it "is ok when an unsaved token carries every required scope" do
      stub_user("ghp_unsaved", scopes: "repo, workflow")

      result = described_class.github_token(token: "ghp_unsaved", required_scopes: %w[ repo workflow ])

      expect(result.ok).to be true
      expect(result.details).to include(login: "ada", missing_scopes: [])
    end

    it "is not ok and names the missing scope when under-scoped" do
      stub_user("ghp_partial", scopes: "repo")

      result = described_class.github_token(token: "ghp_partial", required_scopes: %w[ repo workflow ])

      expect(result.ok).to be false
      expect(result.message).to include("missing the workflow scope")
      expect(result.details).to include(login: "ada", missing_scopes: %w[ workflow ])
    end

    it "is not ok with a helpful message when GitHub rejects the token" do
      stub_request(:get, "https://api.github.com/user")
        .with(headers: { "Authorization" => "token ghp_bad" })
        .to_return(status: 401, body: { message: "Bad credentials" }.to_json, headers: { "Content-Type" => "application/json" })

      result = described_class.github_token(token: "ghp_bad", required_scopes: %w[ repo workflow ])

      expect(result.ok).to be false
      expect(result.message).to include("GitHub rejected this token")
      expect(result.details).to eq({})
    end

    it "refuses a blank token without calling GitHub" do
      result = described_class.github_token(token: "  ", required_scopes: %w[ repo workflow ])

      expect(result.ok).to be false
      expect(result.message).to eq("Paste a token to test it.")
      expect(WebMock).not_to have_requested(:get, "https://api.github.com/user")
    end
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

  describe ".claude_cli_ready" do
    it "probes ambient claude --print without injecting a token" do
      captured = nil
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured = kwargs
        instance_double(ProcessRunner, run: runner_result)
      end

      result = described_class.claude_cli_ready(user: user)

      expect(result.ok).to be true
      expect(result.message).to include("Claude already works on this machine")
      expect(captured[:env]).not_to have_key("CLAUDE_CODE_OAUTH_TOKEN")
      expect(captured[:command]).to include("claude", "--print")
    end

    it "reports not-authenticated when the ambient probe fails" do
      allow(ProcessRunner).to receive(:new) do
        instance_double(ProcessRunner, run: runner_result(exit_status: 1))
      end

      result = described_class.claude_cli_ready(user: user)

      expect(result.ok).to be false
      expect(result.message).to include("not authenticated on this machine")
    end
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

  it "raises ArgumentError for an unknown credential" do
    expect {
      described_class.call(user: user, credential: "unknown_credential")
    }.to raise_error(ArgumentError, /Unknown credential/)
  end

  describe "codex_auth_json credential" do
    let(:auth_json) { Factories.codex_auth_json(access_token: "access-test") }
    let(:user) do
      Factories.user(codex_auth_mode: "chatgpt_login", codex_auth_json: auth_json)
    end

    it "rejects codex_auth_json tests when Codex is in API key mode" do
      user.update!(codex_auth_mode: "api_key", codex_api_key: "sk-test", codex_auth_json: auth_json)

      result = described_class.call(user: user, credential: "codex_auth_json")

      expect(result.ok).to be false
      expect(result.message).to eq("Codex is set to API key mode.")
    end

    it "reports missing auth.json when not configured" do
      user.update!(codex_auth_json: nil)

      result = described_class.call(user: user, credential: "codex_auth_json")

      expect(result.ok).to be false
      expect(result.message).to eq("Codex ChatGPT auth.json is not configured.")
    end
  end

  describe "CREDENTIAL_PROBE_METHODS registry" do
    it "covers all expected credential types" do
      expect(described_class::CREDENTIAL_PROBE_METHODS.keys).to match_array(
        %w[github_token claude_oauth_token codex_api_key codex_auth_json gemini_api_key]
      )
    end
  end
end
