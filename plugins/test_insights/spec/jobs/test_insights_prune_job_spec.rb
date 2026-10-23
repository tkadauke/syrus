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

  def create_isolated_repro_attempt(**attrs)
    TestInsights::IsolatedReproAttempt.create!(
      { repository: repo, grader_name: "rspec", suite_name: "MySpec", name: "it does the thing",
        sha: "c" * 40, reproduced: false, command: "bundle exec rspec", output: "ok" }.merge(attrs)
    )
  end

  it "deletes TestInsights::IsolatedReproAttempt rows older than RETAIN_AFTER" do
    old   = create_isolated_repro_attempt
    fresh = create_isolated_repro_attempt(name: "a fresh example")
    old.update_columns(created_at: (TestInsights::IsolatedReproAttempt::RETAIN_AFTER + 1.day).ago)

    expect { described_class.perform_now }.to change { TestInsights::IsolatedReproAttempt.count }.by(-1)
    expect(TestInsights::IsolatedReproAttempt.exists?(old.id)).to be false
    expect(TestInsights::IsolatedReproAttempt.exists?(fresh.id)).to be true
  end

  it "logs a count consistent with RunDiagnosticPruneJob's style" do
    test_run = create_test_run
    old_case = create_case(test_run)
    old_case.update_columns(created_at: (TestInsights::TestCase::RETAIN_AFTER + 1.day).ago)
    old_run = create_test_run(grader_name: "rspec-old-run")
    old_run.update_columns(created_at: (TestInsights::TestRun::RETAIN_AFTER + 1.day).ago)
    old_attempt = create_isolated_repro_attempt
    old_attempt.update_columns(created_at: (TestInsights::IsolatedReproAttempt::RETAIN_AFTER + 1.day).ago)

    messages = []
    allow(Rails.logger).to receive(:info) { |message| messages << message }

    described_class.perform_now

    expect(messages).to include("[TestInsightsPruneJob] deleted 1 test_insight_cases")
    expect(messages).to include("[TestInsightsPruneJob] deleted 1 test_insight_runs")
    expect(messages).to include("[TestInsightsPruneJob] deleted 1 test_insight_isolated_repro_attempts")
  end

  it "deletes prunable rows in bounded batches" do
    test_run = create_test_run
    old_cases = 3.times.map { create_case(test_run) }
    old_cases.each { |test_case| test_case.update_columns(created_at: (TestInsights::TestCase::RETAIN_AFTER + 1.day).ago) }
    stub_const("TestInsightsPruneJob::DELETE_BATCH_SIZE", 2)

    deletes = []
    allow(TestInsights::TestCase).to receive(:where).and_wrap_original do |method, conditions|
      deletes << conditions.fetch(:id).size if conditions.is_a?(Hash) && conditions.key?(:id)
      method.call(conditions)
    end

    described_class.perform_now

    expect(deletes).to eq([ 2, 1 ])
    expect(TestInsights::TestCase.where(id: old_cases.map(&:id))).to be_empty
  end

  it "bounds each pruning pass" do
    test_run = create_test_run
    old_cases = 3.times.map { create_case(test_run) }
    old_cases.each { |test_case| test_case.update_columns(created_at: (TestInsights::TestCase::RETAIN_AFTER + 1.day).ago) }
    stub_const("TestInsightsPruneJob::DELETE_BATCH_SIZE", 1)
    stub_const("TestInsightsPruneJob::MAX_DELETE_BATCHES", 2)

    described_class.perform_now

    expect(TestInsights::TestCase.where(id: old_cases.map(&:id)).count).to eq(1)
  end

  it "does not delete old runs whose cases remain after the bounded case pass" do
    first_run = create_test_run(grader_name: "rspec-first")
    second_run = create_test_run(grader_name: "rspec-second")
    old_time = (TestInsights::TestRun::RETAIN_AFTER + 1.day).ago
    first_run.update_columns(created_at: old_time)
    second_run.update_columns(created_at: old_time)
    first_cases = 2.times.map { create_case(first_run) }
    second_cases = 2.times.map { create_case(second_run) }
    (first_cases + second_cases).each { |test_case| test_case.update_columns(created_at: old_time) }
    stub_const("TestInsightsPruneJob::DELETE_BATCH_SIZE", 2)
    stub_const("TestInsightsPruneJob::MAX_DELETE_BATCHES", 1)

    described_class.perform_now

    expect(TestInsights::TestRun.exists?(first_run.id)).to be false
    expect(TestInsights::TestRun.exists?(second_run.id)).to be true
    expect(TestInsights::TestCase.where(test_run_id: second_run.id).count).to eq(2)
    expect(TestInsights::TestCase.where.not(test_run_id: TestInsights::TestRun.select(:id))).to be_empty
  end

  it "is a no-op when nothing is prunable" do
    test_run = create_test_run
    create_case(test_run)
    create_isolated_repro_attempt

    expect { described_class.perform_now }.not_to change { TestInsights::TestCase.count }
    expect { described_class.perform_now }.not_to change { TestInsights::TestRun.count }
    expect { described_class.perform_now }.not_to change { TestInsights::IsolatedReproAttempt.count }
  end
end
