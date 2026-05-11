require "rails_helper"

RSpec.describe IngestPolicy do
  let(:repository) { Factories.repository(trigger_label: "syrus") }

  IngestPolicyIssue = Struct.new(:number, :state, :labels, :pull_request, :body, :assignees, keyword_init: true)
  IngestPolicyIssueWithComments = Struct.new(:number, :state, :labels, :pull_request, :body, :assignees, :comments, keyword_init: true)
  IngestPolicyLabel = Struct.new(:name)
  IngestPolicyAssignee = Struct.new(:login)
  IngestPolicyComment = Struct.new(:body)

  def issue(state: "open", labels: %w[syrus], pull_request: nil, body: nil, assignees: [])
    IngestPolicyIssue.new(
      number: 1,
      state: state,
      labels: labels.map { |n| IngestPolicyLabel.new(n) },
      pull_request: pull_request,
      body: body,
      assignees: assignees.map { |login| IngestPolicyAssignee.new(login) }
    )
  end

  it "allows an issue with the trigger label" do
    expect(IngestPolicy.evaluate(issue, repository).allow).to be true
  end

  it "denies pull requests" do
    result = IngestPolicy.evaluate(issue(pull_request: { url: "x" }), repository)
    expect(result.allow).to be false
    expect(result.reason).to match(/pull request/)
  end

  it "denies closed issues" do
    result = IngestPolicy.evaluate(issue(state: "closed"), repository)
    expect(result.allow).to be false
    expect(result.reason).to match(/closed/)
  end

  it "denies opt-out via syrus-skip label" do
    result = IngestPolicy.evaluate(issue(labels: %w[syrus syrus-skip]), repository)
    expect(result.allow).to be false
    expect(result.reason).to match(/syrus-skip/)
  end

  it "denies issues missing the trigger label" do
    result = IngestPolicy.evaluate(issue(labels: %w[bug]), repository)
    expect(result.allow).to be false
    expect(result.reason).to match(/missing trigger label/)
  end

  it "allows an issue body mention of the authenticated bot login" do
    result = IngestPolicy.evaluate(issue(labels: %w[bug], body: "Please @syrus-bot handle this."), repository, bot_login: "syrus-bot")
    expect(result.allow).to be true
  end

  it "allows an issue comment mention of the authenticated bot login" do
    result = IngestPolicy.evaluate(
      issue(labels: %w[bug]),
      repository,
      bot_login: "syrus-bot",
      comments: [ IngestPolicyComment.new("@syrus-bot this is yours now") ]
    )
    expect(result.allow).to be true
  end

  it "allows assignment to the authenticated bot login" do
    result = IngestPolicy.evaluate(issue(labels: %w[bug], assignees: %w[syrus-bot]), repository, bot_login: "syrus-bot")
    expect(result.allow).to be true
  end

  it "allows assignment when GitHub returns hash-shaped assignees" do
    issue = issue(labels: %w[bug])
    issue.assignees = [
      { "login" => "someone-else" },
      { login: "syrus-bot" }
    ]

    result = IngestPolicy.evaluate(issue, repository, bot_login: "syrus-bot")

    expect(result.allow).to be true
  end

  it "fetches comments when the comments count is unknown" do
    issue = IngestPolicyIssueWithComments.new(
      number: 1,
      state: "open",
      labels: [ IngestPolicyLabel.new("bug") ],
      pull_request: nil,
      body: nil,
      assignees: [],
      comments: nil
    )
    policy = described_class.new(issue, repository, bot_login: "syrus-bot", trigger_config: RepoTriggerConfig.new, comments: [])

    expect(policy.needs_comments?).to be true
  end

  it "respects .syrus.yml opt-out for mention triggers" do
    config = RepoTriggerConfig.new(mentions: false)
    result = IngestPolicy.evaluate(issue(labels: %w[bug], body: "@syrus-bot"), repository, bot_login: "syrus-bot", trigger_config: config)
    expect(result.allow).to be false
  end

  it "respects .syrus.yml opt-out for assignment triggers" do
    config = RepoTriggerConfig.new(assignments: false)
    result = IngestPolicy.evaluate(issue(labels: %w[bug], assignees: %w[syrus-bot]), repository, bot_login: "syrus-bot", trigger_config: config)
    expect(result.allow).to be false
  end

  it "respects a custom trigger_label on the repository" do
    repo = Factories.repository(trigger_label: "automate")
    result = IngestPolicy.evaluate(issue(labels: %w[syrus]), repo)
    expect(result.allow).to be false
    result_pass = IngestPolicy.evaluate(issue(labels: %w[automate]), repo)
    expect(result_pass.allow).to be true
  end
end
