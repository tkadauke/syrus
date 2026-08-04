require "rails_helper"

RSpec.describe GithubAuthenticatedGit do
  let(:user) { Factories.user(github_token: "ghp_pat") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:git) { instance_double(GitRunner) }
  let(:installation) do
    Factories.installation(
      user: user,
      github_installation_id: 987,
      cached_token: "ghs_expired",
      cached_token_expires_at: 1.hour.from_now
    )
  end

  before do
    AppSetting.current.update!(github_app_id: 123, github_app_private_key_pem: "stub-pem")
    allow(GithubAppClient).to receive(:app_jwt).and_return("app-jwt")
    repository.update!(installation: installation)
    allow(repository).to receive(:authenticated_push_url) do |token|
      "https://x-access-token:#{token}@github.com/acme/widgets.git"
    end
  end

  def stub_installation_token(token:)
    stub_request(:post, "https://api.github.com/app/installations/987/access_tokens")
      .with(headers: { "Authorization" => "Bearer app-jwt" })
      .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                 body: { token: token, expires_at: 1.hour.from_now.iso8601 }.to_json)
  end

  it "invalidates a rejected installation token, refreshes it, and retries git once with App auth" do
    expired_url = "https://x-access-token:ghs_expired@github.com/acme/widgets.git"
    fresh_url = "https://x-access-token:ghs_fresh@github.com/acme/widgets.git"
    auth_error = GitRunner::GitError.new(
      [ "fetch", expired_url, "refs/heads/main" ],
      128,
      "remote: Invalid username or token.\nfatal: Authentication failed"
    )
    stub_installation_token(token: "ghs_fresh")
    allow(git).to receive(:run).with("fetch", expired_url, "refs/heads/main").and_raise(auth_error)
    allow(git).to receive(:run).with("fetch", fresh_url, "refs/heads/main").and_return("ok")

    result = described_class.run(repository: repository, user: user, git: git, operation_type: "git_fetch") do |url|
      git.run("fetch", url, "refs/heads/main")
    end

    expect(result).to eq("ok")
    expect(installation.reload.cached_token).to eq("ghs_fresh")
    expect(GithubAuthFallbackDiagnostic.count).to eq(0)
  end

  it "falls back to PAT with diagnostics when refreshed App auth is still rejected" do
    run = Factories.job(repository: repository, issue_number: 88).initial_run
    Thread.current[:syrus_current_run] = run
    expired_url = "https://x-access-token:ghs_expired@github.com/acme/widgets.git"
    fresh_url = "https://x-access-token:ghs_fresh@github.com/acme/widgets.git"
    pat_url = "https://x-access-token:ghp_pat@github.com/acme/widgets.git"
    expired_error = GitRunner::GitError.new([ "push", expired_url ], 128, "fatal: Authentication failed")
    fresh_error = GitRunner::GitError.new([ "push", fresh_url ], 128, "remote: Invalid username or token.")
    stub_installation_token(token: "ghs_fresh")
    allow(git).to receive(:run).with("push", expired_url).and_raise(expired_error)
    allow(git).to receive(:run).with("push", fresh_url).and_raise(fresh_error)
    allow(git).to receive(:run).with("push", pat_url).and_return("pushed")

    result = described_class.run(repository: repository, user: user, git: git, operation_type: "git_push") do |url|
      git.run("push", url)
    end

    expect(result).to eq("pushed")
    diagnostic = GithubAuthFallbackDiagnostic.last
    expect(diagnostic).to have_attributes(
      repository_id: repository.id,
      installation_id: installation.id,
      operation_type: "git_push",
      error_class: "GitRunner::GitError",
      refresh_attempted: true,
      refresh_succeeded: true,
      run_id: run.id
    )
    expect(run.job_logs.last).to have_attributes(kind: "github_auth_fallback")
  ensure
    Thread.current[:syrus_current_run] = nil
  end
end
