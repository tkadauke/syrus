require "rails_helper"

RSpec.describe TestInsights::RunResults do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def create_workflow_run!(job:, trigger_kind: "initial", created_at: Time.current)
    workflow = Workflow.create!(job: job, user: job.user, trigger_kind: trigger_kind, agent_provider: job.agent_provider, created_at: created_at, updated_at: created_at)
    step = workflow.steps.create!(kind: "grader", position: 0, created_at: created_at, updated_at: created_at)
    step.runs.create!(job: job, user: job.user, trigger_kind: trigger_kind, agent_provider: job.agent_provider, created_at: created_at, updated_at: created_at)
  end

  def create_result!(run:, grader_name: "rspec", cases:)
    test_run = TestRun.create!(
      run: run,
      repository: run.job.repository,
      grader_name: grader_name,
      total_count: cases.size,
      passed_count: cases.count { |attrs| attrs.fetch(:status) == "passed" },
      failed_count: cases.count { |attrs| attrs.fetch(:status) == "failed" },
      skipped_count: cases.count { |attrs| attrs.fetch(:status) == "skipped" },
      error_count: cases.count { |attrs| attrs.fetch(:status) == "error" },
      duration_ms: cases.sum { |attrs| attrs.fetch(:duration_ms, 0).to_i }
    )

    cases.each do |attrs|
      TestCase.create!(
        test_run: test_run,
        repository: run.job.repository,
        suite_name: attrs.fetch(:suite_name),
        name: attrs.fetch(:name),
        status: attrs.fetch(:status),
        duration_ms: attrs[:duration_ms],
        failure_message: attrs[:failure_message],
        created_at: attrs.fetch(:created_at, Time.current),
        updated_at: attrs.fetch(:created_at, Time.current)
      )
    end

    test_run
  end

  it "returns an empty job payload when no workflow has ingested tests" do
    job = Factories.job(user: user, repository: repository)

    payload = described_class.for_job(user: user, job_id: job.id)

    expect(payload[:job][:id]).to eq(job.id)
    expect(payload[:workflow]).to be_nil
    expect(payload[:test_runs]).to eq([])
    expect(payload.dig(:totals, :total_count)).to eq(0)
  end

  it "returns the latest workflow with ingested tests for a job" do
    job = Factories.job(user: user, repository: repository)
    create_result!(run: job.initial_run, cases: [
      { suite_name: "Old", name: "fails", status: "failed", duration_ms: 10 }
    ])
    latest_run = create_workflow_run!(job: job, trigger_kind: "retry", created_at: 1.minute.from_now)
    create_result!(run: latest_run, cases: [
      { suite_name: "New", name: "passes", status: "passed", duration_ms: 20 }
    ])

    payload = described_class.for_job(user: user, job_id: job.id)

    expect(payload.dig(:workflow, :id)).to eq(latest_run.workflow_id)
    expect(payload.fetch(:test_runs).sole[:total_count]).to eq(1)
  end

  it "filters run-level results by grader name" do
    job = Factories.job(user: user, repository: repository)
    run = job.initial_run
    create_result!(run: run, grader_name: "rspec", cases: [
      { suite_name: "Ruby", name: "passes", status: "passed", duration_ms: 10 }
    ])
    create_result!(run: run, grader_name: "vitest", cases: [
      { suite_name: "React", name: "fails", status: "failed", duration_ms: 20 }
    ])

    payload = described_class.for_run(user: user, run_id: run.id, grader_name: "vitest")

    expect(payload.fetch(:test_runs).map { |test_run| test_run[:grader_name] }).to eq([ "vitest" ])
    expect(payload.dig(:totals, :failed_count)).to eq(1)
  end

  it "bounds failed/error cases and reports omitted failed/error count" do
    job = Factories.job(user: user, repository: repository)
    run = job.initial_run
    create_result!(run: run, cases: [
      { suite_name: "Spec", name: "one", status: "failed", duration_ms: 10 },
      { suite_name: "Spec", name: "two", status: "error", duration_ms: 20 },
      { suite_name: "Spec", name: "three", status: "passed", duration_ms: 30 }
    ])

    payload = described_class.for_run(user: user, run_id: run.id, case_limit: 1)

    expect(payload.dig(:test_runs, 0, :failed_error_cases).size).to eq(1)
    expect(payload.dig(:truncation, :omitted_failed_error_cases)).to eq(1)
  end
end
