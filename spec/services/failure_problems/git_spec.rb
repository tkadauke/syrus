require "rails_helper"

RSpec.describe FailureProblems::Git do
  def git_error(command, exit_status, output)
    GitRunner::GitError.new(command, exit_status, output)
  end

  def classify(...) = described_class.for(git_error(...))

  # Verbatim shapes from production git failures (URLs redacted as GitRunner
  # redacts them).
  it "declares a mid-pack disconnect a retryable transport failure" do
    problem = classify(%w[fetch origin main], 128, <<~OUT)
      error: RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly: CANCEL (err 8)
      fetch-pack: unexpected disconnect while reading sideband packet
      fatal: early EOF
      fatal: fetch-pack: invalid index-pack output
    OUT

    expect(problem.code).to eq("git_transport_transient")
    expect(problem).to be_retryable
    expect(problem.evidence[:transport_error]).to include("RPC failed")
  end

  it "declares a refused connection a retryable transport failure" do
    problem = classify(%w[ls-remote --heads https://x-access-token:[REDACTED]@github.com/acme/widgets.git refs/heads/main], 128,
                       "fatal: unable to access 'https://github.com/acme/widgets.git/': Failed to connect to github.com port 443 after 2547 ms: Could not connect to server")

    expect(problem.code).to eq("git_transport_transient")
  end

  it "declares a 5xx push rejection a retryable transport failure" do
    problem = classify(%w[push origin HEAD:refs/heads/feature], 1, <<~OUT)
      To https://github.com/acme/widgets.git
       ! [remote rejected]     HEAD -> feature (Internal Server Error)
      error: failed to push some refs to 'https://github.com/acme/widgets.git'
    OUT

    expect(problem.code).to eq("git_transport_transient")
  end

  it "declares a non-fast-forward push rejection a diverged branch" do
    problem = classify(%w[push origin HEAD:refs/heads/feature], 1, <<~OUT)
       ! [rejected]        HEAD -> feature (non-fast-forward)
      error: failed to push some refs to 'https://github.com/acme/widgets.git'
    OUT

    expect(problem.code).to eq("branch_diverged")
    expect(problem).not_to be_retryable
  end

  it "declares a rebase conflict non-retryable" do
    problem = classify(%w[rebase main], 1, <<~OUT)
      Auto-merging app/models/widget.rb
      CONFLICT (content): Merge conflict in app/models/widget.rb
      error: could not apply dd0da2776... Add widgets
      hint: Resolve all conflicts manually, mark them as resolved with
    OUT

    expect(problem.code).to eq("git_conflict")
    expect(problem).not_to be_retryable
  end

  it "declares a missing remote ref non-retryable and names it" do
    problem = classify(%w[fetch origin +refs/heads/syrus/direct-1:refs/remotes/origin/syrus/direct-1], 128,
                       "fatal: couldn't find remote ref refs/heads/syrus/direct-1")

    expect(problem.code).to eq("git_ref_missing")
    expect(problem.evidence[:ref]).to eq("refs/heads/syrus/direct-1")
  end

  it "declares refused credentials non-retryable" do
    problem = classify(%w[fetch origin], 128, <<~OUT)
      remote: Invalid username or token. Password authentication is not supported for Git operations.
      fatal: Authentication failed for 'https://github.com/acme/widgets.git/'
    OUT

    expect(problem.code).to eq("git_auth_denied")
    expect(problem).not_to be_retryable
  end

  it "does not call a transport-sounding failure transient when git also says the ref is missing" do
    problem = classify(%w[fetch origin feature], 128, <<~OUT)
      fatal: couldn't find remote ref feature
      fatal: the remote end hung up unexpectedly
    OUT

    expect(problem.code).to eq("git_ref_missing")
  end

  it "makes no claim about a failure its output does not explain" do
    expect(classify(%w[merge-base --is-ancestor a b], 1, "")).to be_nil
    expect(classify(%w[commit -m x], 1, "nothing to commit, working tree clean")).to be_nil
  end
end
