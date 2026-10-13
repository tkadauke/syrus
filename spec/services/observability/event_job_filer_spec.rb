require "rails_helper"

RSpec.describe Observability::EventJobFiler do
  let(:user) { Factories.user }

  before do
    AppSetting.current.update!(report_issue_repo_slug: "operator/syrus")
  end

  def browser_error
    BrowserErrorEvent.record!(
      user: user,
      payload: {
        "fingerprint" => "github-fallback",
        "message" => "undefined is not an object",
        "path" => "/jobs/3188"
      }
    )
  end

  it "returns the existing GitHub issue when the same event is filed twice" do
    event = browser_error
    router = instance_double(BugReports::Router)
    allow(BugReports::Router).to receive(:new).with(user: user).and_return(router)
    allow(router).to receive(:mode).and_return(:github_issue)
    allow(router).to receive(:call).and_return(
      BugReports::Router::Result.new(issue_url: "https://github.example/operator/syrus/issues/1", mode: :github_issue)
    )

    first = described_class.new(user: user, event_type: "browser_error", event_id: event.id).call
    second = described_class.new(user: user, event_type: "browser_error", event_id: event.id).call

    expect(first).to be_success
    expect(second).to be_success
    expect(second.issue_url).to eq(first.issue_url)
    expect(router).to have_received(:call).once
    expect(ObservabilityEventFiling.sole).to have_attributes(
      event_type: "browser_error",
      event_id: event.id,
      issue_url: first.issue_url,
      mode: "github_issue"
    )
  end

  it "retries an unfiled claim when routing fails" do
    event = browser_error
    router = instance_double(BugReports::Router)
    allow(BugReports::Router).to receive(:new).with(user: user).and_return(router)
    allow(router).to receive(:mode).and_return(:github_issue)
    allow(router).to receive(:call).and_return(
      BugReports::Router::Result.new(error_code: "github_token_required", error_message: "GitHub token required", mode: :github_issue),
      BugReports::Router::Result.new(issue_url: "https://github.example/operator/syrus/issues/1", mode: :github_issue)
    )

    failed = described_class.new(user: user, event_type: "browser_error", event_id: event.id).call
    retried = described_class.new(user: user, event_type: "browser_error", event_id: event.id).call

    expect(failed).not_to be_success
    expect(failed.error_code).to eq("github_token_required")
    expect(retried).to be_success
    expect(retried.issue_url).to eq("https://github.example/operator/syrus/issues/1")
    expect(router).to have_received(:call).twice
    expect(ObservabilityEventFiling.sole.issue_url).to eq(retried.issue_url)
  end
end
