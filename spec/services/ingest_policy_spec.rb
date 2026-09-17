require "rails_helper"

RSpec.describe IngestPolicy do
  let(:repository) { Factories.repository(trigger_label: "syrus") }

  FakeIssue = Struct.new(:number, :state, :labels, :pull_request, keyword_init: true) do
    def respond_to_missing?(_method, _ = false) = true
  end

  FakeLabel = Struct.new(:name)

  def issue(state: "open", labels: %w[syrus], pull_request: nil)
    FakeIssue.new(number: 1, state: state, labels: labels.map { |n| FakeLabel.new(n) }, pull_request: pull_request)
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

  it "respects a custom trigger_label on the repository" do
    repo = Factories.repository(trigger_label: "automate")
    result = IngestPolicy.evaluate(issue(labels: %w[syrus]), repo)
    expect(result.allow).to be false
    result_pass = IngestPolicy.evaluate(issue(labels: %w[automate]), repo)
    expect(result_pass.allow).to be true
  end
end
