require "rails_helper"

RSpec.describe PrCommentIngester do
  let(:owner) { Factories.user(github_handle: "alice") }
  let(:repo) { Factories.repository(user: owner, feedback_policy: "auto") }
  let(:job) { Factories.job(user: owner, repository: repo, issue_number: 10) }

  CommentStub = Struct.new(:id, :body, :created_at, :user)

  def make_comment(id:, login:, body:, has_path: false)
    user = Struct.new(:login).new(login)
    CommentStub.new(id, body, Time.current, user)
  end

  before do
    allow(PrCommentClassifier).to receive(:call) do |body:, **|
      PrCommentClassifier::Result.new(actionable: true, reason: "requests a change", error: nil)
    end
  end

  def call(comments, pr_type: "direct", comment_kind: "issue")
    described_class.call(
      job: job,
      comments: comments,
      pr_type: pr_type,
      comment_kind: comment_kind,
      user: owner,
      agent_provider: "claude"
    )
  end

  it "creates PrReviewComment records for new comments" do
    comment = make_comment(id: 101, login: "alice", body: "Fix the typo")

    expect {
      call([ comment ])
    }.to change { PrReviewComment.count }.by(1)

    record = PrReviewComment.last
    expect(record.job).to eq(job)
    expect(record.github_comment_id).to eq(101)
    expect(record.github_handle).to eq("alice")
    expect(record.attributed_to).to eq("job_owner")
    expect(record.actionable).to be true
    expect(record.pr_type).to eq("direct")
    expect(record.comment_kind).to eq("issue")
  end

  it "skips comments that are already recorded" do
    comment = make_comment(id: 101, login: "alice", body: "Fix the typo")
    PrReviewComment.create!(
      job: job, pr_type: "direct", comment_kind: "issue",
      github_comment_id: 101, github_handle: "alice",
      attributed_to: "job_owner", actionable: true, body: "Fix the typo"
    )

    expect {
      call([ comment ])
    }.not_to change { PrReviewComment.count }
  end

  it "returns qualifying records for actionable job_owner comments" do
    comment = make_comment(id: 102, login: "alice", body: "Add tests")
    result = call([ comment ])
    expect(result.qualifying_records).not_to be_empty
    expect(result.any_qualifying?).to be true
  end

  it "returns qualifying records for actionable member comments when feedback_policy is auto" do
    member = Factories.user(github_handle: "bob")
    repo.repository_memberships.create!(user: member, role: "collaborator")

    comment = make_comment(id: 103, login: "bob", body: "Please refactor this")
    result = call([ comment ])
    expect(result.qualifying_records).not_to be_empty
  end

  it "does not qualify member comments when feedback_policy is confirm" do
    repo.update!(feedback_policy: "confirm")
    member = Factories.user(github_handle: "bob")
    repo.repository_memberships.create!(user: member, role: "collaborator")

    comment = make_comment(id: 104, login: "bob", body: "Please refactor this")
    result = call([ comment ])
    expect(result.qualifying_records).to be_empty
    expect(result.non_qualifying_records).not_to be_empty
  end

  it "does not qualify external actionable comments when feedback_policy is confirm" do
    repo.update!(feedback_policy: "confirm")
    comment = make_comment(id: 105, login: "outsider", body: "Add feature X please")
    result = call([ comment ])
    expect(result.qualifying_records).to be_empty
  end

  it "does not qualify non-actionable comments" do
    allow(PrCommentClassifier).to receive(:call).and_return(
      PrCommentClassifier::Result.new(actionable: false, reason: "just praise", error: nil)
    )
    comment = make_comment(id: 106, login: "alice", body: "LGTM!")
    result = call([ comment ])
    expect(result.qualifying_records).to be_empty
    expect(result.non_qualifying_records).not_to be_empty
  end

  it "classifies coverage report comments as non-actionable without calling the provider classifier" do
    comment = make_comment(
      id: 109,
      login: "alice",
      body: "#{CoverageReport::PrCommentFormatter::MARKER}\n## Test Coverage Report"
    )

    result = call([ comment ])

    expect(PrCommentClassifier).not_to have_received(:call)
    expect(result.qualifying_records).to be_empty
    record = PrReviewComment.find_by(github_comment_id: 109)
    expect(record.actionable).to be false
    expect(result.non_qualifying_records).to contain_exactly(record)
  end

  it "defaults actionable to true when classifier fails" do
    allow(PrCommentClassifier).to receive(:call).and_return(
      PrCommentClassifier::Result.new(actionable: true, reason: nil, error: "timeout")
    )
    comment = make_comment(id: 107, login: "alice", body: "Some comment")
    result = call([ comment ])
    expect(result.qualifying_records).not_to be_empty
    record = PrReviewComment.find_by(github_comment_id: 107)
    expect(record.actionable).to be true
  end

  it "attributes external comments correctly" do
    comment = make_comment(id: 108, login: "stranger", body: "Bug here")
    call([ comment ])
    record = PrReviewComment.find_by(github_comment_id: 108)
    expect(record.attributed_to).to eq("external")
  end
end
