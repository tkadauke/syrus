require "rails_helper"

RSpec.describe TestInsights::RunResults do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def build_test_run(run:, grader_name: "rspec", **attrs)
    TestRun.create!(
      run: run,
      repository: repository,
      grader_name: grader_name,
      total_count: attrs.fetch(:total_count, 1),
      passed_count: attrs.fetch(:passed_count, 1),
      failed_count: attrs.fetch(:failed_count, 0),
      skipped_count: attrs.fetch(:skipped_count, 0),
      error_count: attrs.fetch(:error_count, 0),
      duration_ms: attrs.fetch(:duration_ms, 100)
    )
  end

  def build_test_case(test_run:, **attrs)
    TestCase.create!(
      test_run: test_run,
      repository: repository,
      test_identity: attrs.fetch(:test_identity, nil),
      name: attrs.fetch(:name, "example"),
      suite_name: attrs.fetch(:suite_name, "ExampleSpec"),
      status: attrs.fetch(:status, "passed"),
      file_path: attrs.fetch(:file_path, "spec/example_spec.rb"),
      duration_ms: attrs.fetch(:duration_ms, 50),
      failure_message: attrs.fetch(:failure_message, nil),
      failure_backtrace: attrs.fetch(:failure_backtrace, nil),
      output: attrs.fetch(:output, nil)
    )
  end

  it "returns an empty job payload when no workflow has ingested tests" do
    job = Factories.job(user: user, repository: repository)

    payload = described_class.for_job(job: job)

    expect(payload).to include(job_id: job.id, job_slug: job.slug, workflow_id: nil, test_runs: [])
    expect(payload.fetch(:truncation)).to include(failed_error_cases_returned: 0, suites_included: false)
  end

  it "returns compact passing run summaries without suites by default" do
    job = Factories.job(user: user, repository: repository)
    run = job.initial_run
    test_run = build_test_run(run: run, total_count: 2, passed_count: 2, duration_ms: 250)
    build_test_case(test_run: test_run, name: "passes")

    payload = described_class.for_run(run: run)

    expect(payload).to include(job_id: job.id, workflow_id: run.workflow_id, run_id: run.id)
    expect(payload.fetch(:test_runs).first).to include(
      id: test_run.id,
      grader_name: "rspec",
      total_count: 2,
      passed_count: 2,
      failed_count: 0,
      duration_ms: 250,
      failed_error_cases: []
    )
    expect(payload.fetch(:test_runs).first).not_to have_key(:suites)
  end

  it "includes bounded failed and error cases with flakiness annotations" do
    job = Factories.job(user: user, repository: repository)
    run = job.initial_run
    identity = TestIdentity.create!(
      repository: repository,
      fingerprint: TestIdentity.fingerprint_for(suite_name: "FlakySpec", name: "fails sometimes"),
      suite_name: "FlakySpec",
      name: "fails sometimes"
    )
    test_run = build_test_run(run: run, total_count: 3, passed_count: 1, failed_count: 1, error_count: 1)
    build_test_case(test_run: test_run, test_identity: identity, suite_name: "FlakySpec", name: "fails sometimes", status: "passed")
    failing = build_test_case(test_run: test_run, test_identity: identity, suite_name: "FlakySpec", name: "fails sometimes", status: "failed", failure_message: "bad", output: "x" * 3.kilobytes)
    build_test_case(test_run: test_run, suite_name: "OtherSpec", name: "errors", status: "error", failure_message: "boom")

    payload = described_class.for_run(run: run, case_limit: 1)
    cases = payload.dig(:test_runs, 0, :failed_error_cases)

    expect(cases.map { |test_case| test_case.fetch(:id) }).to eq([ failing.id ])
    expect(cases.first.dig(:failure, :message, :text)).to eq("bad")
    expect(cases.first.dig(:failure, :output, :truncated)).to be(true)
    expect(cases.first.dig(:flakiness, :failed_count)).to eq(1)
    expect(cases.first.dig(:flakiness, :total_count)).to eq(2)
    expect(payload.fetch(:truncation)).to include(failed_error_cases_returned: 1, failed_error_cases_omitted: 1)
  end

  it "filters job results to the latest workflow with ingested tests and optional grader name" do
    job = Factories.job(user: user, repository: repository)
    older_run = job.initial_run
    older_test_run = build_test_run(run: older_run, grader_name: "rspec")
    build_test_case(test_run: older_test_run, name: "old")

    newer_workflow = Workflow.create!(job: job, trigger_kind: "retry", created_at: 1.hour.from_now)
    step = newer_workflow.steps.create!(kind: "implement", position: 0)
    newer_run = step.runs.create!(job: job, trigger_kind: "retry")
    build_test_run(run: newer_run, grader_name: "rspec")
    jest = build_test_run(run: newer_run, grader_name: "jest")
    build_test_case(test_run: jest, name: "new")

    payload = described_class.for_job(job: job, grader_name: "jest")

    expect(payload).to include(workflow_id: newer_workflow.id, run_id: nil, grader_name: "jest")
    expect(payload.fetch(:test_runs).map { |test_run| test_run.fetch(:grader_name) }).to eq([ "jest" ])
  end

  it "can include slow cases and full suite grouping" do
    job = Factories.job(user: user, repository: repository)
    run = job.initial_run
    test_run = build_test_run(run: run, total_count: 2, passed_count: 2)
    build_test_case(test_run: test_run, name: "fast", suite_name: "A", duration_ms: 10)
    build_test_case(test_run: test_run, name: "slow", suite_name: "A", duration_ms: 500)

    payload = described_class.for_run(run: run, include_slow_cases: true, include_suites: true, case_limit: 1)
    run_payload = payload.fetch(:test_runs).first

    expect(run_payload.fetch(:slow_cases).map { |test_case| test_case.fetch(:name) }).to eq([ "slow" ])
    expect(run_payload.fetch(:slow_cases_omitted)).to eq(1)
    expect(run_payload.dig(:suites, 0, :test_cases).map { |test_case| test_case.fetch(:name) }).to eq(%w[fast slow])
    expect(payload.fetch(:truncation)).to include(slow_cases_returned: 1, slow_cases_omitted: 1, suites_included: true)
  end
end
