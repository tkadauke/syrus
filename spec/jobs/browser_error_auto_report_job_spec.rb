require "rails_helper"

RSpec.describe BrowserErrorAutoReportJob do
  let(:user) { Factories.user }

  def set_feature(enabled)
    Feature.find_or_create_by!(slug: "browser_error_auto_reports") do |feature|
      feature.category = "Operations"
      feature.name = "Browser error auto reports"
    end.update!(enabled: enabled)
    Feature.clear_enabled_cache!("browser_error_auto_reports")
  end

  def browser_error(fingerprint: "abc123", revision: "sha-one")
    BrowserErrorEvent.create!(
      user: user,
      occurred_at: Time.current,
      app_revision: revision,
      fingerprint: fingerprint,
      name: "TypeError",
      message: "undefined is not an object (evaluating 'n.map')",
      stack: "at JobDetails.tsx:42",
      component_stack: "JobDetails",
      path: "/jobs/3188",
      route_id: "job",
      route_params: { "id" => "3188" },
      url: "https://syrus.example/jobs/3188"
    )
  end

  it "does nothing when the feature is disabled" do
    set_feature(false)
    event = browser_error

    described_class.perform_now(event.id)

    expect(BrowserErrorAutoReport.count).to eq(0)
  end

  it "files one bug report when enabled" do
    set_feature(true)
    event = browser_error
    job = Factories.job_record(user: user)
    router = instance_double(BugReports::Router)
    allow(BugReports::Router).to receive(:new).with(user: user).and_return(router)
    allow(router).to receive(:call).and_return(BugReports::Router::Result.new(job: job, mode: :direct_job))

    described_class.perform_now(event.id)

    report = BrowserErrorAutoReport.sole
    expect(report).to be_reported
    expect(report.job).to eq(job)
    expect(router).to have_received(:call).with(
      title: include("Browser error: undefined is not an object"),
      description: include("Browser error event: ##{event.id}", "Path: /jobs/3188", "JobDetails"),
      context: include(
        source: "browser_error_auto_report",
        browser_error_event_id: event.id,
        route_params: { "id" => "3188" }
      )
    )
  end

  it "does not file duplicate reports for the same fingerprint and revision" do
    set_feature(true)
    first = browser_error
    second = browser_error
    router = instance_double(BugReports::Router)
    allow(BugReports::Router).to receive(:new).and_return(router)
    allow(router).to receive(:call).and_return(BugReports::Router::Result.new(issue_url: "https://github.example/issues/1", mode: :github_issue))

    described_class.perform_now(first.id)
    described_class.perform_now(second.id)

    expect(BrowserErrorAutoReport.count).to eq(1)
    expect(router).to have_received(:call).once
  end

  it "records a failed report claim when routing fails" do
    set_feature(true)
    event = browser_error
    router = instance_double(BugReports::Router)
    allow(BugReports::Router).to receive(:new).and_return(router)
    allow(router).to receive(:call).and_return(
      BugReports::Router::Result.new(error_code: "github_token_required", error_message: "GitHub token required", mode: :github_issue)
    )

    described_class.perform_now(event.id)

    report = BrowserErrorAutoReport.sole
    expect(report).to be_failed
    expect(report.error_message).to eq("GitHub token required")
  end
end
