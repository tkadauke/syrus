require "rails_helper"

RSpec.describe TestInsightsPruneJob do
  let(:job)  { Factories.job }
  let(:run)  { job.initial_run }
  let(:repo) { job.repository }

  def create_test_run(**attrs)
    TestInsights::TestRun.create!(
      { run: run, repository: repo, grader_name: "rspec",
        total_count: 1, passed_count: 1, failed_count: 0,
        skipped_count: 0, error_count: 0 }.merge(attrs)
    )
  end

  def create_case(test_run, **attrs)
    TestInsights::TestCase.create!(
      { test_run: test_run, repository: repo, name: "it does the thing",
        suite_name: "MySpec", status: "passed" }.merge(attrs)
    )
  end

  it "deletes TestInsights::TestCase rows older than RETAIN_AFTER" do
    test_run = create_test_run
    old   = create_case(test_run)
    fresh = create_case(test_run)
    old.update_columns(created_at: (TestInsights::TestCase::RETAIN_AFTER + 1.day).ago)

    expect { described_class.perform_now }.to change { TestInsights::TestCase.count }.by(-1)
    expect(TestInsights::TestCase.exists?(old.id)).to be false
    expect(TestInsights::TestCase.exists?(fresh.id)).to be true
  end

  it "deletes TestInsights::TestRun rows older than RETAIN_AFTER" do
    old   = create_test_run(grader_name: "rspec-old")
    fresh = create_test_run(grader_name: "rspec-fresh")
    old.update_columns(created_at: (TestInsights::TestRun::RETAIN_AFTER + 1.day).ago)

    expect { described_class.perform_now }.to change { TestInsights::TestRun.count }.by(-1)
    expect(TestInsights::TestRun.exists?(old.id)).to be false
    expect(TestInsights::TestRun.exists?(fresh.id)).to be true
  end

  it "logs a count consistent with RunDiagnosticPruneJob's style" do
    test_run = create_test_run
    old_case = create_case(test_run)
    old_case.update_columns(created_at: (TestInsights::TestCase::RETAIN_AFTER + 1.day).ago)
    old_run = create_test_run(grader_name: "rspec-old-run")
    old_run.update_columns(created_at: (TestInsights::TestRun::RETAIN_AFTER + 1.day).ago)

    messages = []
    allow(Rails.logger).to receive(:info) { |message| messages << message }

    described_class.perform_now

    expect(messages).to include("[TestInsightsPruneJob] deleted 1 test_insight_cases")
    expect(messages).to include("[TestInsightsPruneJob] deleted 1 test_insight_runs")
  end

  it "is a no-op when nothing is prunable" do
    test_run = create_test_run
    create_case(test_run)

    expect { described_class.perform_now }.not_to change { TestInsights::TestCase.count }
    expect { described_class.perform_now }.not_to change { TestInsights::TestRun.count }
  end
end
