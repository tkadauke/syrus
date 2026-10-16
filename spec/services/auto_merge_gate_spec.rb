require "rails_helper"
require "ostruct"

RSpec.describe AutoMergeGate do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }
  let(:job) { Factories.job(user: user, repository: repository, pr_number: 7, branch_name: "syrus/issue-42-1") }
  let(:client) { instance_double(GithubClient) }

  def pr(labels: [], mergeable_state: "clean", state: "open", head_sha: "abc")
    OpenStruct.new(
      state: state,
      mergeable_state: mergeable_state,
      labels: labels.map { |name| OpenStruct.new(name: name) },
      head: OpenStruct.new(sha: head_sha)
    )
  end

  def comment(body:, created_at: Time.current, association: "OWNER")
    OpenStruct.new(
      id: SecureRandom.random_number(10_000),
      body: body,
      created_at: created_at,
      author_association: association,
      user: OpenStruct.new(login: "operator")
    )
  end

  def commit(date:)
    OpenStruct.new(
      sha: SecureRandom.hex(20),
      commit: OpenStruct.new(committer: OpenStruct.new(date: date), author: OpenStruct.new(date: date))
    )
  end

  def review(state:, commit_id: "abc", association: "MEMBER", login: "reviewer")
    OpenStruct.new(
      state: state,
      commit_id: commit_id,
      author_association: association,
      user: OpenStruct.new(login: login)
    )
  end

  before do
    allow(client).to receive(:pull_request).and_return(pr)
    allow(client).to receive(:pr_reviews).and_return([])
    allow(client).to receive(:pr_issue_comments).and_return([])
    allow(client).to receive(:pr_commits).and_return([])
  end

  it "allows a formal APPROVED review when the PR is clean" do
    allow(client).to receive(:pr_reviews).and_return([ review(state: "APPROVED") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).to be_merge_ready
    expect(result.outcome).to eq(:ready)
  end

  it "blocks when a reviewer's approval is superseded by requested changes" do
    allow(client).to receive(:pr_reviews).and_return([
      review(state: "APPROVED"),
      review(state: "CHANGES_REQUESTED")
    ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
    expect(result.reason).to include("not approved")
  end

  it "blocks a dismissed approval" do
    allow(client).to receive(:pr_reviews).and_return([
      review(state: "APPROVED"),
      review(state: "DISMISSED")
    ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
  end

  it "ignores commented reviews when selecting a reviewer's latest state" do
    allow(client).to receive(:pr_reviews).and_return([
      review(state: "APPROVED"),
      review(state: "COMMENTED")
    ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).to be_merge_ready
  end

  it "blocks an approval for an earlier head commit" do
    allow(client).to receive(:pr_reviews).and_return([ review(state: "APPROVED", commit_id: "old-head") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
  end

  it "blocks an approval from a reviewer without write access" do
    allow(client).to receive(:pr_reviews).and_return([
      review(state: "APPROVED", association: "CONTRIBUTOR")
    ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
  end

  it "allows a Syrus-side operator approval without any GitHub review" do
    job.update_columns(state: "approved", approved_at: Time.current, approved_via: "operator")

    result = described_class.new(job: job.reload, client: client).evaluate

    expect(result).to be_merge_ready
    expect(result).to be_approved
  end

  # Regression: AutoMerge runs the gate AFTER the Job has already
  # transitioned :approved → :landing. The previous implementation
  # used Job#approved? (the AASM state predicate) and returned false
  # in this state, falling through to GitHub checks and emitting a
  # misleading "PR is not approved" error. The fix uses persistent
  # metadata (approved_via + approved_at) which the state machine
  # preserves across the :approved → :landing transition.
  it "still recognises operator approval after the Job has transitioned to landing" do
    job.update_columns(state: "landing", approved_at: Time.current, approved_via: "operator")

    result = described_class.new(job: job.reload, client: client).evaluate

    expect(result).to be_merge_ready
    expect(result).to be_approved
  end

  # Regression: bulk-approve from the dashboard sets approved_via to
  # "bulk", not "operator". The first version of syrus_side_approval?
  # checked only "operator" and silently dropped bulk approvals
  # through to the GitHub-side fallback, which then returned "not
  # approved" if no PR review existed. Production hit this on a
  # bulk-approved batch of four Jobs that all failed with
  # "auto_merge: PR is not approved" — see the SYRUS_SIDE_APPROVAL_VIAS
  # constant for the full whitelist.
  it "recognises bulk-approve (approved_via: \"bulk\") as a Syrus-side approval" do
    job.update_columns(state: "landing", approved_at: Time.current, approved_via: "bulk")

    result = described_class.new(job: job.reload, client: client).evaluate

    expect(result).to be_merge_ready
    expect(result).to be_approved
  end

  it "recognises auto-rule approval (approved_via: \"auto_rule\") as a Syrus-side approval" do
    job.update_columns(state: "landing", approved_at: Time.current, approved_via: "auto_rule")

    result = described_class.new(job: job.reload, client: client).evaluate

    expect(result).to be_merge_ready
    expect(result).to be_approved
  end

  it "ignores github_review approvals as a Syrus-side gate bypass" do
    # github_review approvals are already counted via pr_reviews — they
    # shouldn't be double-counted through the local-DB path. With no
    # APPROVED review on the GitHub side, the gate should block.
    job.update_columns(state: "approved", approved_at: Time.current, approved_via: "github_review")

    result = described_class.new(job: job.reload, client: client).evaluate

    expect(result).not_to be_merge_ready
    expect(result.reason).to include("not approved")
  end

  it "ignores operator approval that has been cleared by fail_landing" do
    # fail_landing nulls approved_at; this should drop the gate-bypass
    # even though approved_via might still be set on the row.
    job.update_columns(state: "landing_failed", approved_at: nil, approved_via: "operator")

    result = described_class.new(job: job.reload, client: client).evaluate

    expect(result).not_to be_merge_ready
    expect(result.reason).to include("not approved")
  end

  it "allows a write-access slash approval from the PR author of record" do
    allow(client).to receive(:pr_issue_comments).and_return([ comment(body: "/approve") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).to be_merge_ready
  end

  it "blocks slash approval from readers" do
    allow(client).to receive(:pr_issue_comments).and_return([ comment(body: "/approve", association: "CONTRIBUTOR") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
    expect(result.reason).to include("not approved")
  end

  it "blocks stale slash approval when a later commit exists" do
    approved_at = 10.minutes.ago
    allow(client).to receive(:pr_issue_comments).and_return([ comment(body: "/approve", created_at: approved_at) ])
    allow(client).to receive(:pr_commits).and_return([ commit(date: 1.minute.ago) ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
  end

  it "respects the opt-out label" do
    allow(client).to receive(:pull_request).and_return(pr(labels: [ AutoMergeGate::OPT_OUT_LABEL ]))
    allow(client).to receive(:pr_reviews).and_return([ review(state: "APPROVED") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
    expect(result.reason).to include(AutoMergeGate::OPT_OUT_LABEL)
  end

  it "requires the per-repository opt-in" do
    repository.update!(auto_merge_enabled: false)
    allow(client).to receive(:pr_reviews).and_return([ review(state: "APPROVED") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
    expect(result.reason).to include("repository")
  end

  it "blocks until dependencies are satisfied" do
    prerequisite = Factories.job(user: user, repository: repository, issue_number: 99)
    JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
    allow(client).to receive(:pr_reviews).and_return([ review(state: "APPROVED") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
    expect(result.reason).to include("dependencies")
  end

  it "reports a closed PR as closed" do
    allow(client).to receive(:pull_request).and_return(pr(state: "closed"))
    allow(client).to receive(:pr_reviews).and_return([ review(state: "APPROVED") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result.outcome).to eq(:closed)
    expect(result).to be_closed
  end

  {
    "unknown" => :transient,
    "has_hooks" => :transient,
    "behind" => :needs_rebase,
    "dirty" => :needs_rebase,
    "blocked" => :blocked,
    "clean" => :ready,
    # `unstable` = non-required CI check failing; the merge call
    # itself would succeed. Operator approved knowing the state.
    "unstable" => :ready
  }.each do |mergeable_state, outcome|
    it "returns #{outcome.inspect} for mergeable_state=#{mergeable_state.inspect}" do
      allow(client).to receive(:pull_request).and_return(pr(mergeable_state: mergeable_state))
      allow(client).to receive(:pr_reviews).and_return([ review(state: "APPROVED") ])

      result = described_class.new(job: job, client: client).evaluate

      expect(result.outcome).to eq(outcome)
      expect(result.merge_ready?).to eq(outcome == :ready)
      expect(result.reason).to include(mergeable_state) unless outcome == :ready
    end
  end
end
