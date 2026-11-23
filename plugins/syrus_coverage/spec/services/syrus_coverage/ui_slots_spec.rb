require "rails_helper"

RSpec.describe SyrusCoverage::UiSlots do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first || Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude", state: "succeeded") }

  it "contributes nothing to the job slot when no workflow has a coverage artifact" do
    expect(described_class.ui_slots(slot: "job.detail", context: { job: job })).to eq([])
  end

  it "contributes the card with a trimmed artifact once coverage was recorded" do
    workflow.update!(artifacts: { "coverage" => { "summary" => { "lines_pct" => 90.0 }, "diff_annotations" => { "a.rb" => {} }, "pr_comment_body" => "x" } })

    panel = described_class.ui_slots(slot: "job.detail", context: { job: job.reload }).sole

    expect(panel[:component]).to eq("syrus_coverage/CoverageCard")
    expect(panel.dig(:props, :coverage)).to eq("summary" => { "lines_pct" => 90.0 })
  end

  it "contributes the trend sparkline to the repository page" do
    panel = described_class.ui_slots(slot: "repository.detail", context: { repository: job.repository }).sole

    expect(panel[:component]).to eq("syrus_coverage/CoverageSparkline")
  end

  it "contributes nothing to other slots" do
    expect(described_class.ui_slots(slot: "dashboard.jobs.notice", context: { job: job })).to eq([])
  end
end
