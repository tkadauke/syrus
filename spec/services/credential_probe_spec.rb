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

    it "is ok when an unsaved classic token carries repository access without workflow" do
      stub_user("ghp_unsaved", scopes: "repo")

      result = described_class.github_token(token: "ghp_unsaved", required_scopes: %w[ repo ])

      expect(result.ok).to be true
      expect(result.details).to include(login: "ada", missing_scopes: [])
    end

    it "accepts public_repo as classic repository access" do
      stub_user("ghp_unsaved", scopes: "public_repo")

      result = described_class.github_token(token: "ghp_unsaved", required_scopes: %w[ repo ])

      expect(result.ok).to be true
      expect(result.details).to include(login: "ada", scopes: %w[public_repo], missing_scopes: [])
    end

    it "does not accept a fine-grained token until repository workflow-file and Checks access are probed" do
      stub_user("github_pat_unsaved", scopes: "")

      result = described_class.github_token(token: "github_pat_unsaved", required_scopes: %w[ repo ])

      expect(result.ok).to be false
      expect(result.message).to eq("Fine-grained token authenticated as ada. Enter a repository slug so Syrus can verify repository write, GitHub Actions workflow-file access, and Checks read access before saving.")
      expect(result.details).to include(
        login: "ada",
        scopes: [],
        missing_scopes: [],
        fine_grained: true,
        needs_repository_probe: true,
        required_repository_permissions: {
          contents: "write",
          pull_requests: "write",
          workflows: "write",
          checks: "read"
        }
      )
    end

    it "accepts a fine-grained token after probing workflow-file write and Checks read access on the repository" do
      allow(SecureRandom).to receive(:hex).with(8).and_return("abc123ef")
      stub_user("github_pat_unsaved", scopes: "")
      stub_request(:get, "https://api.github.com/repos/acme/widgets")
        .with(headers: { "Authorization" => "token github_pat_unsaved" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { default_branch: "main" }.to_json)
      stub_request(:get, "https://api.github.com/repos/acme/widgets/git/refs/heads/main")
        .with(headers: { "Authorization" => "token github_pat_unsaved" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { object: { sha: "base123" } }.to_json)
      checks_read = stub_request(:get, "https://api.github.com/repos/acme/widgets/commits/base123/check-runs")
        .with(headers: { "Authorization" => "token github_pat_unsaved" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { total_count: 0, check_runs: [] }.to_json)
      create_ref = stub_request(:post, "https://api.github.com/repos/acme/widgets/git/refs")
        .with(
          headers: { "Authorization" => "token github_pat_unsaved" },
          body: { ref: "refs/heads/syrus-token-probe-abc123ef", sha: "base123" }.to_json
        )
        .to_return(status: 201, headers: { "Content-Type" => "application/json" }, body: {}.to_json)
      create_workflow = stub_request(:put, "https://api.github.com/repos/acme/widgets/contents/.github/workflows/syrus-token-probe.yml")
        .with(headers: { "Authorization" => "token github_pat_unsaved" })
        .to_return(status: 201, headers: { "Content-Type" => "application/json" }, body: {}.to_json)
      delete_ref = stub_request(:delete, "https://api.github.com/repos/acme/widgets/git/refs/heads/syrus-token-probe-abc123ef")
        .with(headers: { "Authorization" => "token github_pat_unsaved" })
        .to_return(status: 204, body: "")

      result = described_class.github_token(
        token: "github_pat_unsaved",
        required_scopes: %w[ repo ],
        probe_repository: "acme/widgets"
      )

      expect(result.ok).to be true
      expect(result.message).to eq("Fine-grained token can write workflow files and read Checks on acme/widgets as ada. Also grant Pull requests write; Syrus cannot verify it without creating a probe PR.")
      expect(result.details).to include(
        login: "ada",
        fine_grained: true,
        probed_repository: "acme/widgets",
        workflow_file_write: true,
        checks_read: true,
        unverified_repository_permissions: %w[pull_requests:write]
      )
      expect(checks_read).to have_been_requested
      expect(create_ref).to have_been_requested
      expect(create_workflow).to have_been_requested
      expect(delete_ref).to have_been_requested
    end

    it "rejects a fine-grained token when Checks read access is forbidden" do
      allow(SecureRandom).to receive(:hex).with(8).and_return("abc123ef")
      stub_user("github_pat_unsaved", scopes: "")
      stub_request(:get, "https://api.github.com/repos/acme/widgets")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { default_branch: "main" }.to_json)
      stub_request(:get, "https://api.github.com/repos/acme/widgets/git/refs/heads/main")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { object: { sha: "base123" } }.to_json)
      checks_read = stub_request(:get, "https://api.github.com/repos/acme/widgets/commits/base123/check-runs")
        .to_return(status: 403, headers: { "Content-Type" => "application/json" }, body: { message: "Resource not accessible by personal access token" }.to_json)
      create_ref = stub_request(:post, "https://api.github.com/repos/acme/widgets/git/refs")

      result = described_class.github_token(
        token: "github_pat_unsaved",
        required_scopes: %w[ repo ],
        probe_repository: "acme/widgets"
      )

      expect(result.ok).to be false
      expect(result.message).to eq("Fine-grained token authenticated as ada, but GitHub refused the Checks read probe on acme/widgets. Grant Checks read for that repository.")
      expect(result.details).to include(
        probed_repository: "acme/widgets",
        missing_repository_permissions: %w[checks:read]
      )
      expect(checks_read).to have_been_requested
      expect(create_ref).not_to have_been_requested
    end

    it "cleans up the probe branch when the workflow-file write is forbidden" do
      allow(SecureRandom).to receive(:hex).with(8).and_return("abc123ef")
      stub_user("github_pat_unsaved", scopes: "")
      stub_request(:get, "https://api.github.com/repos/acme/widgets")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { default_branch: "main" }.to_json)
      stub_request(:get, "https://api.github.com/repos/acme/widgets/git/refs/heads/main")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { object: { sha: "base123" } }.to_json)
      stub_request(:get, "https://api.github.com/repos/acme/widgets/commits/base123/check-runs")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { total_count: 0, check_runs: [] }.to_json)
      stub_request(:post, "https://api.github.com/repos/acme/widgets/git/refs")
        .to_return(status: 201, headers: { "Content-Type" => "application/json" }, body: {}.to_json)
      stub_request(:put, "https://api.github.com/repos/acme/widgets/contents/.github/workflows/syrus-token-probe.yml")
        .to_return(status: 403, headers: { "Content-Type" => "application/json" }, body: { message: "Resource not accessible by personal access token" }.to_json)
      delete_ref = stub_request(:delete, "https://api.github.com/repos/acme/widgets/git/refs/heads/syrus-token-probe-abc123ef")
        .to_return(status: 204, body: "")

      result = described_class.github_token(
        token: "github_pat_unsaved",
        required_scopes: %w[ repo ],
        probe_repository: "acme/widgets"
      )

      expect(result.ok).to be false
      expect(result.message).to include("refused the workflow-file write probe")
      expect(result.details).to include(
        probed_repository: "acme/widgets",
        missing_repository_permissions: %w[contents:write workflows:write]
      )
      expect(delete_ref).to have_been_requested
    end

    it "is not ok and names the missing repository scope when under-scoped" do
      stub_user("ghp_partial", scopes: "")

      result = described_class.github_token(token: "ghp_partial", required_scopes: %w[ repo ])

      expect(result.ok).to be false
      expect(result.message).to include("missing the repo scope")
      expect(result.message).to include("classic token with repo for private repositories or public_repo for public repositories")
      expect(result.message).to include("add workflow only if agents must edit GitHub Actions workflow files")
      expect(result.details).to include(login: "ada", missing_scopes: %w[ repo ])
    end

    it "is not ok with a helpful message when GitHub rejects the token" do
      stub_request(:get, "https://api.github.com/user")
        .with(headers: { "Authorization" => "token ghp_bad" })
        .to_return(status: 401, body: { message: "Bad credentials" }.to_json, headers: { "Content-Type" => "application/json" })

      result = described_class.github_token(token: "ghp_bad", required_scopes: %w[ repo ])

      expect(result.ok).to be false
      expect(result.message).to include("GitHub rejected this token")
      expect(result.details).to eq({})
    end

    it "refuses a blank token without calling GitHub" do
      result = described_class.github_token(token: "  ", required_scopes: %w[ repo ])

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
