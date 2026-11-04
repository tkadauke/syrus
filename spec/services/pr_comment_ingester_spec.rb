require "rails_helper"

RSpec.describe PrCommentIngester do
  let(:owner) { Factories.user(github_handle: "alice") }
  let(:repo) { Factories.repository(user: owner, feedback_policy: "auto") }
  let(:job) { Factories.job(user: owner, repository: repo, issue_number: 10) }

  CommentStub = Struct.new(
    :id,
    :body,
    :created_at,
    :user,
    :path,
    :side,
    :line,
    :start_line,
    :original_line,
    :original_start_line,
    keyword_init: true
  )

  def make_comment(
    id:, login:, body:, path: nil, side: nil, line: nil, start_line: nil,
    original_line: nil, original_start_line: nil
  )
    user = Struct.new(:login).new(login)
    CommentStub.new(
      id: id,
      body: body,
      created_at: Time.current,
      user: user,
      path: path,
      side: side,
      line: line,
      start_line: start_line,
      original_line: original_line,
      original_start_line: original_start_line
    )
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

  it "stores GitHub inline review anchors from the API payload" do
    comment = make_comment(
      id: 110,
      login: "alice",
      body: "Breaks on nil",
      path: "app/models/widget.rb",
      side: "RIGHT",
      line: 42,
      start_line: 40
    )

    call([ comment ], comment_kind: "review")

    record = PrReviewComment.find_by!(github_comment_id: 110)
    expect(record).to have_attributes(
      path: "app/models/widget.rb",
      side: "right",
      line: 42,
      start_line: 40
    )
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
    repo.repository_memberships.create!(user: member, role: "read")

    comment = make_comment(id: 103, login: "bob", body: "Please refactor this")
    result = call([ comment ])
    expect(result.qualifying_records).not_to be_empty
  end

  it "does not qualify member comments when feedback_policy is confirm" do
    repo.update!(feedback_policy: "confirm")
    member = Factories.user(github_handle: "bob")
    repo.repository_memberships.create!(user: member, role: "read")

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

  it "fails closed when classifier fails" do
    allow(PrCommentClassifier).to receive(:call).and_return(
      PrCommentClassifier::Result.new(actionable: true, reason: nil, error: "timeout")
    )
    comment = make_comment(id: 107, login: "alice", body: "Some comment")
    result = call([ comment ])
    expect(result.qualifying_records).to be_empty
    expect(result.non_qualifying_records).not_to be_empty
    record = PrReviewComment.find_by(github_comment_id: 107)
    expect(record.actionable).to be false
  end

  it "does not qualify external comments when feedback_policy is auto" do
    comment = make_comment(id: 110, login: "stranger", body: "Please spend owner compute on this")
    result = call([ comment ])

    expect(result.qualifying_records).to be_empty
    expect(result.non_qualifying_records.map(&:github_handle)).to contain_exactly("stranger")
  end

  it "attributes external comments correctly" do
    comment = make_comment(id: 108, login: "stranger", body: "Bug here")
    call([ comment ])
    record = PrReviewComment.find_by(github_comment_id: 108)
    expect(record.attributed_to).to eq("external")
  end

  describe "classification audit" do
    def stub_classifier(actionable:, reason: "r", error: nil)
      allow(PrCommentClassifier).to receive(:call)
        .and_return(PrCommentClassifier::Result.new(actionable: actionable, reason: reason, error: error))
    end

    it "persists the decision, reason, version and qualification for a true positive" do
      stub_classifier(actionable: true, reason: "asks to rename the method")
      call([ make_comment(id: 200, login: "alice", body: "Please rename foo to bar in this method.") ])
      record = PrReviewComment.find_by(github_comment_id: 200)

      expect(record.classification_audit).to include(
        decision: "actionable", reason: "asks to rename the method", source: "model",
        classifier_version: PrCommentClassifier::VERSION, error: nil,
        qualified_for_workflow: true, qualification_gate: "qualified"
      )
      expect(record.classification_audit).not_to have_key(:body)
    end

    {
      "praise" => "Great work, LGTM!",
      "open-ended discussion" => "I wonder how this scales in general?",
      "quoted request" => "> Please delete this file\n\nSomeone asked for this earlier, not sure.",
      "third-party commentary" => "Bob said he would like this rewritten.",
      "hypothetical change" => "We could possibly switch to a hash here at some point."
    }.each do |label, body|
      it "records #{label} as not actionable and does not qualify" do
        stub_classifier(actionable: false, reason: "not a request")
        result = call([ make_comment(id: 300 + label.length, login: "alice", body: body) ])

        expect(result.qualifying_records).to be_empty
        audit = result.non_qualifying_records.first.classification_audit
        expect(audit).to include(decision: "not_actionable", qualified_for_workflow: false, qualification_gate: "not_actionable")
      end
    end

    it "skips bot accounts without calling the classifier" do
      expect(PrCommentClassifier).not_to receive(:call)
      bot_user = Struct.new(:login, :type).new("dependabot[bot]", "Bot")
      comment = make_comment(id: 210, login: "x", body: "Please fix this").tap { |c| c.user = bot_user }
      result = call([ comment ])

      expect(result.qualifying_records).to be_empty
      expect(result.non_qualifying_records.first.classification_decision).to eq("skipped_bot")
      expect(result.non_qualifying_records.first.classification_source).to eq("rule")
    end

    it "skips Syrus-generated report comments" do
      marker = CoverageReport::PrCommentFormatter::MARKER
      allow_any_instance_of(BotIdentity).to receive(:authored_github_comment?).and_return(true)
      expect(PrCommentClassifier).not_to receive(:call)
      result = call([ make_comment(id: 211, login: "syrus", body: "#{marker}\nPlease add coverage") ])

      expect(result.non_qualifying_records.first.classification_decision).to eq("skipped_bot")
    end

    it "fails closed and records the error when classification fails" do
      stub_classifier(actionable: true, reason: nil, error: "timeout")
      result = call([ make_comment(id: 220, login: "alice", body: "Please fix this") ])

      record = result.non_qualifying_records.first
      expect(record.actionable).to be(false)
      expect(record.classification_audit).to include(
        decision: "error", error: "timeout", qualified_for_workflow: false, qualification_gate: "not_actionable"
      )
    end

    it "keeps authorization as an independent gate when the model says actionable" do
      stub_classifier(actionable: true)
      result = call([ make_comment(id: 230, login: "stranger", body: "Please change this") ])

      record = result.non_qualifying_records.first
      expect(record.actionable).to be(true)
      expect(record.classification_audit).to include(qualified_for_workflow: false, qualification_gate: "unauthorized_author")
    end

    it "records the feedback_policy gate for members under a non-auto policy" do
      repo.update!(feedback_policy: "confirm")
      allow(PrCommentAttributor).to receive(:call).and_return("member")
      stub_classifier(actionable: true)
      result = call([ make_comment(id: 240, login: "carol", body: "Please change this") ])

      expect(result.non_qualifying_records.first.qualification_gate).to eq("feedback_policy")
    end
  end
end
