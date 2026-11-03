require "rails_helper"

RSpec.describe GithubPushProtection do
  let(:sha) { "a" * 40 }
  let(:secret_url) { "https://github.com/acme/widgets/security/secret-scanning/unblock-secret/SECRETTOKEN123" }
  let(:remote_output) do
    <<~OUT
      remote: error: GH013: Repository rule violations found for refs/heads/syrus/job-1.
      remote: - GITHUB PUSH PROTECTION
      remote:   —————————————————————————————————————————
      remote:     Resolve the following violations before pushing again
      remote:     - Push cannot contain secrets
      remote:      —— GitHub Personal Access Token ——————————————————————
      remote:       locations:
      remote:         - commit: #{sha}
      remote:           path: config/app.rb:12
      remote:      (?) To push, remove secret from commit(s) or follow this URL to allow the secret.
      remote:      #{secret_url}
    OUT
  end
  let(:command) { [ "push", "https://x-access-token:ghp_abc@github.com/acme/widgets.git", "HEAD:refs/heads/syrus/job-1" ] }

  def git_error(output, cmd = command)
    GitRunner::GitError.new(cmd, 1, output)
  end

  it "classifies a GH013 rejection into sanitized findings" do
    rejected = described_class.reclassify(git_error(remote_output))

    expect(rejected).to be_a(described_class::Rejected).and be_a(GitRunner::GitError)
    expect(rejected.ref).to eq("refs/heads/syrus/job-1")
    expect(rejected.findings.map(&:to_h)).to eq([
      { "secret_type" => "GitHub Personal Access Token", "commit_sha" => sha, "path" => "config/app.rb", "line" => 12 }
    ])
  end

  it "never leaks the bypass URL, tokens or raw output" do
    rejected = described_class.reclassify(git_error(remote_output))
    text = [ rejected.message, rejected.output, rejected.command.join(" ") ].join("\n")

    expect(text).not_to include("SECRETTOKEN123")
    expect(text).not_to include("unblock-secret")
    expect(text).not_to include("ghp_abc")
    expect(text).to include("GitHub Personal Access Token")
  end

  it "leaves other git failures and non-push commands untouched" do
    plain = git_error("remote: error: failed (non-fast-forward)")
    expect(described_class.reclassify(plain)).to equal(plain)

    fetch = git_error(remote_output, [ "fetch", "origin" ])
    expect(described_class.reclassify(fetch)).to equal(fetch)
  end

  it "is applied at the shared authenticated push boundary without auth fallback" do
    user = Factories.user(github_token: "ghp_pat")
    repository = Factories.repository(user: user)
    allow(GithubClient).to receive(:active_installation_for).and_return(nil)
    allow(GithubClient).to receive(:for).and_return(double(access_token: "tok"))
    allow(repository).to receive(:authenticated_push_url) { |t| "https://x-access-token:#{t}@github.com/a/b.git" }

    expect {
      described_class::Rejected # autoload
      GithubAuthenticatedGit.run(repository: repository, user: user, git: nil, operation_type: "git_push") do |_url|
        raise git_error(remote_output)
      end
    }.to raise_error(described_class::Rejected) { |e| expect(e.message).not_to include("unblock-secret") }
  end
end
