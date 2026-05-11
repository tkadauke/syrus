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

  before do
    allow(client).to receive(:pull_request).and_return(pr)
    allow(client).to receive(:pr_reviews).and_return([])
    allow(client).to receive(:pr_issue_comments).and_return([])
    allow(client).to receive(:pr_commits).and_return([])
  end

  it "allows a formal APPROVED review when the PR is clean" do
    allow(client).to receive(:pr_reviews).and_return([ OpenStruct.new(state: "APPROVED") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).to be_merge_ready
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
    allow(client).to receive(:pr_reviews).and_return([ OpenStruct.new(state: "APPROVED") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
    expect(result.reason).to include(AutoMergeGate::OPT_OUT_LABEL)
  end

  it "requires the per-repository opt-in" do
    repository.update!(auto_merge_enabled: false)
    allow(client).to receive(:pr_reviews).and_return([ OpenStruct.new(state: "APPROVED") ])

    result = described_class.new(job: job, client: client).evaluate

    expect(result).not_to be_merge_ready
    expect(result.reason).to include("repository")
  end
end
