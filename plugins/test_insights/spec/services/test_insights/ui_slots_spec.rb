require "rails_helper"

RSpec.describe TestInsights::UiSlots do
  let(:job) { Factories.job }
  let(:run) { job.initial_run }

  def ingest_a_test_run!
    TestInsights::TestRun.create!(
      run: run, repository: job.repository, grader_name: "rspec",
      total_count: 1, passed_count: 1, failed_count: 0, skipped_count: 0, error_count: 0
    )
  end

  it "contributes no Tests tab when the Job has no results" do
    expect(described_class.ui_slots(slot: "job.detail.tab", context: { job: job })).to eq([])
  end

  it "contributes a Tests tab once a run has ingested results" do
    ingest_a_test_run!

    panel = described_class.ui_slots(slot: "job.detail.tab", context: { job: job.reload }).sole

    expect(panel[:key]).to eq("tests")
    expect(panel[:component]).to eq("test_insights/JobTests")
    expect(panel.dig(:props, :job_id)).to eq(job.id)
  end

  it "contributes nothing to other slots" do
    ingest_a_test_run!

    expect(described_class.ui_slots(slot: "job.detail", context: { job: job.reload })).to eq([])
  end

  it "is served through the job.detail.tab slot payload" do
    ingest_a_test_run!

    ids = App::UiSlotsPayload.panels_for(slot: "job.detail.tab", context: { job: job.reload }).map { |p| p[:id] }

    expect(ids).to include("test_insights.job_tests")
  end
end
