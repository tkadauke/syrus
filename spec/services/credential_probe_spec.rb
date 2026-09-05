require "rails_helper"

RSpec.describe CredentialProbe do
  let(:user) do
    Factories.user(
      github_token: "ghp_secret",
      claude_oauth_token: "oat-secret",
      codex_api_key: "sk-codex-secret"
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

  it "raises ArgumentError for an unknown credential" do
    expect {
      described_class.call(user: user, credential: "unknown_credential")
    }.to raise_error(ArgumentError, /Unknown credential/)
  end

  describe "CREDENTIAL_PROBE_METHODS registry" do
    it "covers the credential types owned by core" do
      expect(described_class::CREDENTIAL_PROBE_METHODS.keys).to match_array(
        %w[github_token]
      )
    end
  end
end
