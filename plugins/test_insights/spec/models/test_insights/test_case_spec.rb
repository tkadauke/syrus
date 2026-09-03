require "rails_helper"

RSpec.describe TestInsights::TestCase do
  include ActiveJob::TestHelper

  let(:job)      { Factories.job }
  let(:run)      { job.initial_run }
  let(:repo)     { job.repository }
  let(:test_run) do
    TestInsights::TestRun.create!(run: run, repository: repo, grader_name: "rspec",
                    total_count: 1, passed_count: 1, failed_count: 0,
                    skipped_count: 0, error_count: 0)
  end

  def build_case(**attrs)
    TestInsights::TestCase.new(
      { test_run: test_run, repository: repo,
        name: "it does the thing", suite_name: "MySpec", status: "passed" }.merge(attrs)
    )
  end

  def create_case(**attrs)
    TestInsights::TestCase.create!(
      { test_run: test_run, repository: repo,
        name: "it does the thing", suite_name: "MySpec", status: "passed" }.merge(attrs)
    )
  end

  def backfill_test_identities
    TestInsights::TestIdentity.ensure_for_repository!(repo, index_search: false)
  end

  it "is valid with required attributes" do
    expect(build_case).to be_valid
  end

  it "requires name" do
    expect(build_case(name: nil)).not_to be_valid
  end

  it "requires suite_name" do
    expect(build_case(suite_name: nil)).not_to be_valid
  end

  it "requires a valid status" do
    expect(build_case(status: "pending")).not_to be_valid
  end

  it "accepts all valid statuses" do
    TestInsights::TestCase::STATUSES.each do |s|
      expect(build_case(status: s)).to be_valid, "expected #{s} to be valid"
    end
  end

  it "accepts nil duration_ms" do
    expect(build_case(duration_ms: nil)).to be_valid
  end

  it "rejects negative duration_ms" do
    expect(build_case(duration_ms: -1)).not_to be_valid
  end

  it "accepts nil file_path, output, failure_message, failure_backtrace" do
    expect(build_case(file_path: nil, output: nil, failure_message: nil, failure_backtrace: nil)).to be_valid
  end

  describe "scopes" do
    before do
      TestInsights::TestCase::STATUSES.each do |s|
        test_run.test_cases.create!(repository: repo, name: "case #{s}", suite_name: "S", status: s)
      end
    end

    it "scopes .passed" do
      expect(TestInsights::TestCase.passed.pluck(:status).uniq).to eq([ "passed" ])
    end

    it "scopes .failed" do
      expect(TestInsights::TestCase.failed.pluck(:status).uniq).to eq([ "failed" ])
    end

    it "scopes .skipped" do
      expect(TestInsights::TestCase.skipped.pluck(:status).uniq).to eq([ "skipped" ])
    end

    it "scopes .errored" do
      expect(TestInsights::TestCase.errored.pluck(:status).uniq).to eq([ "error" ])
    end
  end

  describe ".flakiness_score" do
    it "returns nil when no history exists" do
      result = TestInsights::TestCase.flakiness_score(repository: repo, suite_name: "S", name: "nonexistent")
      expect(result).to be_nil
    end

    it "returns score 0.0 when all runs pass" do
      3.times { create_case(status: "passed") }

      result = TestInsights::TestCase.flakiness_score(repository: repo, suite_name: "MySpec", name: "it does the thing")

      expect(result[:score]).to eq(0.0)
      expect(result[:failed_count]).to eq(0)
      expect(result[:total_count]).to eq(3)
      expect(result[:flaky]).to be(false)
    end

    it "returns score 1.0 when all runs fail" do
      3.times { create_case(status: "failed") }

      result = TestInsights::TestCase.flakiness_score(repository: repo, suite_name: "MySpec", name: "it does the thing")

      expect(result[:score]).to eq(1.0)
      expect(result[:flaky]).to be(false)
    end

    it "identifies a flaky test with mixed pass/fail history" do
      2.times { create_case(status: "passed") }
      1.times { create_case(status: "failed") }

      result = TestInsights::TestCase.flakiness_score(repository: repo, suite_name: "MySpec", name: "it does the thing")

      expect(result[:score]).to be_within(0.001).of(1.0 / 3.0)
      expect(result[:failed_count]).to eq(1)
      expect(result[:total_count]).to eq(3)
      expect(result[:flaky]).to be(true)
    end

    it "counts error status as failures" do
      create_case(status: "passed")
      create_case(status: "error")

      result = TestInsights::TestCase.flakiness_score(repository: repo, suite_name: "MySpec", name: "it does the thing")

      expect(result[:failed_count]).to eq(1)
      expect(result[:flaky]).to be(true)
    end

    it "returns run_statuses oldest to newest" do
      create_case(status: "passed")
      create_case(status: "failed")
      create_case(status: "passed")

      result = TestInsights::TestCase.flakiness_score(repository: repo, suite_name: "MySpec", name: "it does the thing")

      expect(result[:run_statuses]).to eq(%w[passed failed passed])
    end

    it "respects the lookback limit" do
      # Create the failure first (oldest), then 25 passes (most recent)
      create_case(status: "failed")
      25.times { create_case(status: "passed") }

      # With lookback 20, only the 20 most recent are considered — all passes
      result = TestInsights::TestCase.flakiness_score(repository: repo, suite_name: "MySpec", name: "it does the thing", lookback: 20)

      expect(result[:total_count]).to eq(20)
      expect(result[:failed_count]).to eq(0)
    end

    it "is scoped to the given repository" do
      other_repo = Factories.repository
      other_job  = Factories.job(repository: other_repo, user: other_repo.user)
      other_run  = other_job.initial_run
      other_tr   = TestInsights::TestRun.create!(run: other_run, repository: other_repo, grader_name: "rspec",
                                   total_count: 1, passed_count: 0, failed_count: 1,
                                   skipped_count: 0, error_count: 0)
      TestInsights::TestCase.create!(test_run: other_tr, repository: other_repo, name: "it does the thing", suite_name: "MySpec", status: "failed")

      # Our repo has no history
      result = TestInsights::TestCase.flakiness_score(repository: repo, suite_name: "MySpec", name: "it does the thing")
      expect(result).to be_nil
    end
  end

  describe ".runtime_percentiles" do
    it "returns nil when no duration data exists" do
      create_case(status: "passed", duration_ms: nil)

      result = TestInsights::TestCase.runtime_percentiles(repository: repo, suite_name: "MySpec", name: "it does the thing")
      expect(result).to be_nil
    end

    it "returns avg, p50, p95 for a sample of durations" do
      # 20 items: 100, 200, ..., 2000
      (1..20).each { |i| create_case(status: "passed", duration_ms: i * 100) }

      result = TestInsights::TestCase.runtime_percentiles(repository: repo, suite_name: "MySpec", name: "it does the thing")

      # avg = (100+200+...+2000)/20 = 21000/20 = 1050
      expect(result[:avg]).to eq(1050)
      # p50: ceil(20*0.5)-1 = 10-1 = 9 => sorted[9] = 1000
      expect(result[:p50]).to eq(1000)
      # p95: ceil(20*0.95)-1 = ceil(19)-1 = 18 => sorted[18] = 1900
      expect(result[:p95]).to eq(1900)
    end

    it "returns correct values for a single sample" do
      create_case(status: "passed", duration_ms: 42)

      result = TestInsights::TestCase.runtime_percentiles(repository: repo, suite_name: "MySpec", name: "it does the thing")

      expect(result[:avg]).to eq(42)
      expect(result[:p50]).to eq(42)
      expect(result[:p95]).to eq(42)
    end

    it "skips nil durations" do
      create_case(status: "passed", duration_ms: nil)
      create_case(status: "passed", duration_ms: 100)
      create_case(status: "failed", duration_ms: 200)

      result = TestInsights::TestCase.runtime_percentiles(repository: repo, suite_name: "MySpec", name: "it does the thing")

      expect(result[:total_count] || result.values.length).to be >= 1
      expect(result[:avg]).to eq(150)
    end
  end

  describe ".top_flaky_tests" do
    it "returns empty array when no test cases exist" do
      expect(TestInsights::TestCase.top_flaky_tests(repository: repo)).to eq([])
    end

    it "returns flaky tests sorted by flakiness_score descending" do
      # Very flaky: 3 failures, 1 pass out of 4
      4.times.with_index do |i|
        s = i < 3 ? "failed" : "passed"
        create_case(name: "very flaky", suite_name: "S", status: s)
      end

      # Slightly flaky: 1 failure, 3 passes out of 4
      4.times.with_index do |i|
        s = i < 1 ? "failed" : "passed"
        create_case(name: "slightly flaky", suite_name: "S", status: s)
      end
      backfill_test_identities

      tests = TestInsights::TestCase.top_flaky_tests(repository: repo)

      expect(tests.size).to eq(2)
      expect(tests.first[:name]).to eq("very flaky")
      expect(tests.first[:flakiness_score]).to be_within(0.001).of(0.75)
      expect(tests.last[:name]).to eq("slightly flaky")
      expect(tests.last[:flakiness_score]).to be_within(0.001).of(0.25)
    end

    it "excludes tests that never passed (all failures are not flaky)" do
      3.times { create_case(name: "always fails", suite_name: "S", status: "failed") }
      backfill_test_identities

      expect(TestInsights::TestCase.top_flaky_tests(repository: repo)).to eq([])
    end

    it "excludes tests that never failed (perfectly stable)" do
      3.times { create_case(name: "always passes", suite_name: "S", status: "passed") }
      backfill_test_identities

      expect(TestInsights::TestCase.top_flaky_tests(repository: repo)).to eq([])
    end

    it "includes avg_duration_ms and last_seen_at" do
      create_case(name: "flaky one", suite_name: "S", status: "passed", duration_ms: 100)
      create_case(name: "flaky one", suite_name: "S", status: "failed", duration_ms: 200)
      backfill_test_identities

      result = TestInsights::TestCase.top_flaky_tests(repository: repo).first

      expect(result[:avg_duration_ms]).to eq(150)
      expect(result[:last_seen_at]).not_to be_nil
    end

    it "respects the limit parameter" do
      5.times.with_index do |i|
        create_case(name: "flaky #{i}", suite_name: "S", status: "passed")
        create_case(name: "flaky #{i}", suite_name: "S", status: "failed")
      end
      backfill_test_identities

      tests = TestInsights::TestCase.top_flaky_tests(repository: repo, limit: 3)
      expect(tests.size).to eq(3)
    end

    it "uses persisted recent stats for the default lookback" do
      create_case(name: "flaky", suite_name: "S", status: "passed", duration_ms: 100)
      create_case(name: "flaky", suite_name: "S", status: "failed", duration_ms: 200)
      backfill_test_identities

      expect_any_instance_of(TestInsights::TestIdentity).not_to receive(:recent_stats)

      test = TestInsights::TestCase.top_flaky_tests(repository: repo).first
      expect(test[:name]).to eq("flaky")
      expect(test[:avg_duration_ms]).to eq(150)
    end

    it "enqueues missing durable test identities instead of building them inline" do
      create_case(name: "flaky", suite_name: "S", status: "passed")
      create_case(name: "flaky", suite_name: "S", status: "failed")

      expect {
        tests = TestInsights::TestCase.top_flaky_tests(repository: repo, lookback: "20", limit: "3")
        expect(tests).to eq([])
      }.to have_enqueued_job(BackfillTestIdentitiesJob).with(repo.id).on_queue("indexing")

      expect(TestInsights::TestIdentity.find_by(repository: repo, name: "flaky")).to be_nil
    end
  end

  describe ".batch_flakiness" do
    it "returns empty hash for empty input" do
      expect(TestInsights::TestCase.batch_flakiness(repo, [])).to eq({})
    end

    it "returns flakiness data keyed by [suite_name, name]" do
      create_case(name: "alpha", suite_name: "S", status: "passed")
      create_case(name: "alpha", suite_name: "S", status: "failed")

      tc = build_case(name: "alpha", suite_name: "S", status: "passed")
      result = TestInsights::TestCase.batch_flakiness(repo, [ tc ])

      data = result[[ "S", "alpha" ]]
      expect(data).not_to be_nil
      expect(data[:flaky]).to be(true)
      expect(data[:failed_count]).to eq(1)
      expect(data[:total_count]).to eq(2)
    end

    it "returns non-flaky data for stable tests" do
      3.times { create_case(name: "stable", suite_name: "S", status: "passed") }

      tc = build_case(name: "stable", suite_name: "S")
      result = TestInsights::TestCase.batch_flakiness(repo, [ tc ])

      data = result[[ "S", "stable" ]]
      expect(data[:flaky]).to be(false)
      expect(data[:score]).to eq(0.0)
    end

    it "limits identity-backed history in SQL to the requested lookback" do
      old_case = create_case(name: "recent", suite_name: "S", status: "passed")
      2.times { create_case(name: "recent", suite_name: "S", status: "failed") }
      identity = TestInsights::TestIdentity.ensure_for_cases!(repository: repo, cases: [ old_case ]).values.first
      TestInsights::TestCase.where(name: "recent", suite_name: "S").update_all(test_identity_id: identity.id)

      tc = build_case(name: "recent", suite_name: "S", test_identity_id: identity.id)
      result = TestInsights::TestCase.batch_flakiness(repo, [ tc ], lookback: 2)

      data = result[[ "S", "recent" ]]
      expect(data[:flaky]).to be(false)
      expect(data[:failed_count]).to eq(2)
      expect(data[:total_count]).to eq(2)
    end
  end
end
