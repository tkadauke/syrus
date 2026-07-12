require "rails_helper"

RSpec.describe Workflows::ChatFeedback do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "open") }

  it "materializes the standard chain with coverage steps always present" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ prepare respond grader_fanout grader_collect coverage_analyze coverage_pr_comment summarize_amend push ]
    )
  end

  it "places coverage_analyze immediately after grader_collect and coverage_pr_comment before summarize_amend" do
    workflow = described_class.instantiate(job: job)

    kinds = workflow.steps.order(:position).pluck(:kind)
    collect_pos   = kinds.index("grader_collect")
    analyze_pos   = kinds.index("coverage_analyze")
    comment_pos   = kinds.index("coverage_pr_comment")
    summarize_pos = kinds.index("summarize_amend")

    expect(analyze_pos).to eq(collect_pos + 1)
    expect(comment_pos).to eq(analyze_pos + 1)
    expect(summarize_pos).to eq(comment_pos + 1)
  end
end
