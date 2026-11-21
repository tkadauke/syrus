require "rails_helper"

RSpec.describe Coworkers::JobGoalSummary do
  JobRecord = Data.define(:issue_title, :issue_body)

  it "uses a descriptive direct Job title" do
    expect(summary("Prepare the quarterly launch report", "Full prompt")).to eq("Prepare the quarterly launch report")
  end

  it "derives generated scheduled titles from the first substantive prompt sentence" do
    expect(summary("Scheduled coworker task: Daily brief", "# Context\n\n- Summarize overnight customer escalations. Include owners."))
      .to eq("Summarize overnight customer escalations.")
  end

  it "ignores metadata and fenced code" do
    body = "Metadata: internal\n```ruby\nputs 'secret'\n```\n\n1. Notify the support lead about the outage. Then update the report."
    expect(summary("Scheduled coworker task", body)).to eq("Notify the support lead about the outage.")
  end

  it "localizes the blank fallback" do
    expect(summary("Scheduled coworker task", "\n# Heading\n")).to eq("No goal summary available")
  end

  it "bounds long summaries without splitting words" do
    result = summary("A #{'carefully described outcome ' * 20}", "")

    expect(result.length).to be <= described_class::MAX_LENGTH
    expect(result).to end_with("...")
  end

  def summary(title, body)
    described_class.new(JobRecord.new(issue_title: title, issue_body: body)).call
  end
end
