require "rails_helper"

RSpec.describe TestInsights::Ingester do
  include ActiveJob::TestHelper

  let(:job)  { Factories.job }
  let(:run)  { job.initial_run }
  let(:repo) { job.repository }

  def parsed_run(passed: 2, failed: 1, skipped: 0, error: 0, duration_ms: 500)
    total = passed + failed + skipped + error
    cases = []
    passed.times  { |i| cases << parsed_case("pass_#{i}", "passed") }
    failed.times  { |i| cases << parsed_case("fail_#{i}", "failed", message: "assertion #{i}") }
    skipped.times { |i| cases << parsed_case("skip_#{i}", "skipped") }
    error.times   { |i| cases << parsed_case("err_#{i}", "error", message: "crash #{i}") }

    JunitXmlParser::ParsedRun.new(
      total_count: total,
      passed_count: passed,
      failed_count: failed,
      skipped_count: skipped,
      error_count: error,
      duration_ms: duration_ms,
      cases: cases
    )
  end

  def parsed_case(name, status, message: nil)
    JunitXmlParser::ParsedCase.new(
      name: name,
      suite_name: "MySpec",
      file_path: nil,
      status: status,
      duration_ms: 100,
      output: nil,
      failure_message: message,
      failure_backtrace: nil
    )
  end

  subject(:ingester) { described_class.new(run: run, grader_name: "rspec", parsed_run: parsed_run) }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  it "creates a TestInsights::TestRun with correct counts and duration" do
    expect { ingester.ingest! }.to change(TestInsights::TestRun, :count).by(1)

    tr = TestInsights::TestRun.find_by!(run: run, grader_name: "rspec")
    expect(tr).to have_attributes(
      repository: repo,
      total_count: 3,
      passed_count: 2,
      failed_count: 1,
      skipped_count: 0,
      error_count: 0,
      duration_ms: 500
    )
  end

  it "creates TestInsights::TestCase rows for each case" do
    expect { ingester.ingest! }.to change(TestInsights::TestCase, :count).by(3)

    tr = TestInsights::TestRun.find_by!(run: run, grader_name: "rspec")
    expect(tr.test_cases.passed.count).to eq(2)
    expect(tr.test_cases.failed.count).to eq(1)
    expect(tr.test_cases.find_by!(name: "fail_0").failure_message).to eq("assertion 0")
  end

  it "creates durable test identities and links executions to them" do
    expect { ingester.ingest! }.to change(TestInsights::TestIdentity, :count).by(3)

    test_case = TestInsights::TestCase.find_by!(name: "fail_0")
    identity = test_case.test_identity
    expect(identity).to have_attributes(
      repository: repo,
      name: "fail_0",
      suite_name: "MySpec",
      last_status: "failed"
    )
  end

  it "indexes durable test identities instead of individual test cases" do
    # Indexing is enqueued rather than written inline: ingestion runs on the
    # compute tier, which has no access to the search database.
    perform_enqueued_jobs(only: IndexTestIdentitiesJob) { ingester.ingest! }

    expect(TestInsights::SearchIndex.search("fail_0", user_id: repo.user_id).map { |row| row[:test_identity_id] }).to eq([ TestInsights::TestIdentity.find_by!(name: "fail_0").id ])
  end

  it "enqueues search indexing onto the indexing queue rather than writing inline" do
    expect { ingester.ingest! }.to have_enqueued_job(IndexTestIdentitiesJob).on_queue("indexing")
  end

  it "refreshes bounded runtime summaries for each identity and grader" do
    ingester.ingest!

    identity = TestInsights::TestIdentity.find_by!(name: "pass_0")
    grader_summary = TestInsights::RuntimeSummary.find_by!(
      test_identity: identity,
      grader_name: "rspec",
      window: TestInsights::RuntimeSummary::RECENT_100_WINDOW
    )
    all_summary = TestInsights::RuntimeSummary.find_by!(
      test_identity: identity,
      grader_name: TestInsights::RuntimeSummary::ALL_GRADERS,
      window: TestInsights::RuntimeSummary::RECENT_100_WINDOW
    )

    expect(grader_summary).to have_attributes(
      repository: repo,
      sample_count: 1,
      avg_duration_ms: 100,
      p50_duration_ms: 100,
      p95_duration_ms: 100
    )
    expect(all_summary.sample_count).to eq(1)
  end

  it "links test cases to the repository" do
    ingester.ingest!
    expect(TestInsights::TestCase.last.repository).to eq(repo)
  end

  it "is idempotent: replaces an existing TestInsights::TestRun on repeated calls" do
    ingester.ingest!
    first_id = TestInsights::TestRun.find_by!(run: run, grader_name: "rspec").id

    second = described_class.new(
      run: run,
      grader_name: "rspec",
      parsed_run: parsed_run(passed: 0, failed: 1, skipped: 0, error: 0, duration_ms: 100)
    )
    second.ingest!

    trs = TestInsights::TestRun.where(run: run, grader_name: "rspec")
    expect(trs.count).to eq(1)
    expect(trs.sole.id).not_to eq(first_id)
    expect(trs.sole.failed_count).to eq(1)
    expect(trs.sole.passed_count).to eq(0)
  end

  it "destroys associated TestCases when replacing a TestInsights::TestRun" do
    ingester.ingest!
    old_tr_id = TestInsights::TestRun.find_by!(run: run, grader_name: "rspec").id

    second = described_class.new(
      run: run,
      grader_name: "rspec",
      parsed_run: parsed_run(passed: 1, failed: 0, skipped: 0, error: 0)
    )
    second.ingest!

    expect(TestInsights::TestCase.where(test_run_id: old_tr_id)).to be_empty
    expect(TestInsights::TestCase.count).to eq(1)
  end

  it "removes runtime summaries for replaced tests that no longer have duration data" do
    ingester.ingest!
    identity = TestInsights::TestIdentity.find_by!(name: "fail_0")

    second = described_class.new(
      run: run,
      grader_name: "rspec",
      parsed_run: parsed_run(passed: 1, failed: 0, skipped: 0, error: 0)
    )
    second.ingest!

    expect(TestInsights::RuntimeSummary.where(test_identity: identity)).to be_empty
  end

  it "keeps one durable identity when replacing a TestInsights::TestRun" do
    ingester.ingest!
    identity_id = TestInsights::TestIdentity.find_by!(name: "fail_0").id

    second = described_class.new(
      run: run,
      grader_name: "rspec",
      parsed_run: parsed_run(passed: 1, failed: 0, skipped: 0, error: 0)
    )
    second.ingest!

    expect(TestInsights::TestIdentity.where(id: identity_id)).to exist
    expect(TestInsights::TestIdentity.find(identity_id).last_status).to eq("failed")
  end

  it "truncates an oversized example name instead of dropping the batch" do
    long_name = "does the thing when the context is " + ("very " * 60) + "long"
    expect(long_name.bytesize).to be > 255

    cases = [
      parsed_case("pass_0", "passed"),
      parsed_case(long_name, "failed", message: "assertion"),
      parsed_case("pass_1", "passed")
    ]
    parsed = JunitXmlParser::ParsedRun.new(
      total_count: 3, passed_count: 2, failed_count: 1, skipped_count: 0, error_count: 0,
      duration_ms: 300, cases: cases
    )
    ingester = described_class.new(run: run, grader_name: "rspec", parsed_run: parsed)

    expect { ingester.ingest! }
      .to change(TestInsights::TestCase, :count).by(3)
      .and change(TestInsights::TestIdentity, :count).by(3)

    tr = TestInsights::TestRun.find_by!(run: run, grader_name: "rspec")
    expect(tr).to have_attributes(total_count: 3, failed_count: 1)

    truncated_case = tr.test_cases.find_by!(status: "failed")
    expect(truncated_case.name.bytesize).to be <= 255
    expect(truncated_case.name).to eq(long_name.safe_byteslice(0, 255))
    expect(truncated_case.test_identity.name.bytesize).to be <= 255
  end

  it "keys identities off the untruncated name so two long names sharing a 255-byte prefix stay distinct" do
    shared_prefix = "a" * 260
    name_a = "#{shared_prefix}-first"
    name_b = "#{shared_prefix}-second"

    cases = [ parsed_case(name_a, "passed"), parsed_case(name_b, "passed") ]
    parsed = JunitXmlParser::ParsedRun.new(
      total_count: 2, passed_count: 2, failed_count: 0, skipped_count: 0, error_count: 0,
      duration_ms: 100, cases: cases
    )
    ingester = described_class.new(run: run, grader_name: "rspec", parsed_run: parsed)

    expect { ingester.ingest! }.to change(TestInsights::TestIdentity, :count).by(2)

    fingerprint_a = TestInsights::TestIdentity.fingerprint_for(suite_name: "MySpec", name: name_a)
    fingerprint_b = TestInsights::TestIdentity.fingerprint_for(suite_name: "MySpec", name: name_b)
    expect(fingerprint_a).not_to eq(fingerprint_b)
    expect(TestInsights::TestIdentity.exists?(fingerprint: fingerprint_a)).to be(true)
    expect(TestInsights::TestIdentity.exists?(fingerprint: fingerprint_b)).to be(true)
  end

  it "isolates a single row's insert failure instead of discarding the whole batch" do
    parsed = parsed_run(passed: 3, failed: 0, skipped: 0, error: 0)
    ingester = described_class.new(run: run, grader_name: "rspec", parsed_run: parsed)

    allow(TestInsights::TestCase).to receive(:insert_all!).and_wrap_original do |original, rows|
      if rows.any? { |row| row[:name] == "pass_1" }
        raise ActiveRecord::ValueTooLong, "Mysql2::Error: Data too long for column 'name' at row 2"
      end

      original.call(rows)
    end
    allow(OperationalLogging).to receive(:ingest)

    expect { ingester.ingest! }.not_to raise_error

    tr = TestInsights::TestRun.find_by!(run: run, grader_name: "rspec")
    expect(tr.total_count).to eq(3)
    expect(TestInsights::TestCase.where(test_run: tr).pluck(:name)).to contain_exactly("pass_0", "pass_2")
    expect(OperationalLogging).to have_received(:ingest).with(hash_including(level: "error", source: "test_insights_ingester")).at_least(:once)
  end

  it "allows different grader names for the same run" do
    ingester.ingest!

    other = described_class.new(
      run: run,
      grader_name: "react-tests",
      parsed_run: parsed_run(passed: 5, failed: 0, skipped: 0, error: 0)
    )
    other.ingest!

    expect(TestInsights::TestRun.where(run: run).count).to eq(2)
    expect(TestInsights::TestRun.where(run: run, grader_name: "react-tests").sole.passed_count).to eq(5)
  end

  it "preserves primary test result rows when search indexing fails" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS test_identity_fts")

    expect { perform_enqueued_jobs(only: IndexTestIdentitiesJob) { ingester.ingest! } }
      .to change(TestInsights::TestRun, :count).by(1)
      .and change(TestInsights::TestCase, :count).by(3)

    expect(TestInsights::TestRun.find_by!(run: run, grader_name: "rspec")).to have_attributes(total_count: 3, failed_count: 1)
  end

  it "preserves primary test result rows when runtime summary refresh fails" do
    allow(TestInsights::RuntimeSummary).to receive(:refresh_many!).and_raise(ArgumentError, "adapter does not support :unique_by")
    allow(Rails.logger).to receive(:warn)

    expect { ingester.ingest! }
      .to change(TestInsights::TestRun, :count).by(1)
      .and change(TestInsights::TestCase, :count).by(3)

    expect(TestInsights::TestRun.find_by!(run: run, grader_name: "rspec")).to have_attributes(total_count: 3, failed_count: 1)
    expect(Rails.logger).to have_received(:warn).with(include("runtime summary refresh failed"))
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS test_identity_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE test_identity_fts
      USING fts5(
        name,
        suite_name,
        file_path,
        test_identity_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        last_status UNINDEXED,
        last_seen_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
