require "rails_helper"

RSpec.describe TestRunIngester do
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

  it "creates a TestRun with correct counts and duration" do
    expect { ingester.ingest! }.to change(TestRun, :count).by(1)

    tr = TestRun.find_by!(run: run, grader_name: "rspec")
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

  it "creates TestCase rows for each case" do
    expect { ingester.ingest! }.to change(TestCase, :count).by(3)

    tr = TestRun.find_by!(run: run, grader_name: "rspec")
    expect(tr.test_cases.passed.count).to eq(2)
    expect(tr.test_cases.failed.count).to eq(1)
    expect(tr.test_cases.find_by!(name: "fail_0").failure_message).to eq("assertion 0")
  end

  it "links test cases to the repository" do
    ingester.ingest!
    expect(TestCase.last.repository).to eq(repo)
  end

  it "is idempotent: replaces an existing TestRun on repeated calls" do
    ingester.ingest!
    first_id = TestRun.find_by!(run: run, grader_name: "rspec").id

    second = described_class.new(
      run: run,
      grader_name: "rspec",
      parsed_run: parsed_run(passed: 0, failed: 1, skipped: 0, error: 0, duration_ms: 100)
    )
    second.ingest!

    trs = TestRun.where(run: run, grader_name: "rspec")
    expect(trs.count).to eq(1)
    expect(trs.sole.id).not_to eq(first_id)
    expect(trs.sole.failed_count).to eq(1)
    expect(trs.sole.passed_count).to eq(0)
  end

  it "destroys associated TestCases when replacing a TestRun" do
    ingester.ingest!
    old_tr_id = TestRun.find_by!(run: run, grader_name: "rspec").id

    second = described_class.new(
      run: run,
      grader_name: "rspec",
      parsed_run: parsed_run(passed: 1, failed: 0, skipped: 0, error: 0)
    )
    second.ingest!

    expect(TestCase.where(test_run_id: old_tr_id)).to be_empty
    expect(TestCase.count).to eq(1)
  end

  it "allows different grader names for the same run" do
    ingester.ingest!

    other = described_class.new(
      run: run,
      grader_name: "react-tests",
      parsed_run: parsed_run(passed: 5, failed: 0, skipped: 0, error: 0)
    )
    other.ingest!

    expect(TestRun.where(run: run).count).to eq(2)
    expect(TestRun.where(run: run, grader_name: "react-tests").sole.passed_count).to eq(5)
  end
end
