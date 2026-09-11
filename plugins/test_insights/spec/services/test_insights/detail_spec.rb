require "rails_helper"

RSpec.describe TestInsights::Detail do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def make_identity(name: "tracks history", suite_name: "HistorySpec")
    TestInsights::TestIdentity.create!(
      repository: repository,
      fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: suite_name, name: name),
      suite_name: suite_name,
      name: name
    )
  end

  def make_case(identity:, status: "passed", created_at: Time.current, duration_ms: 100)
    run = Factories.job(user: user, repository: repository).initial_run
    test_run = TestInsights::TestRun.create!(
      run: run,
      repository: repository,
      grader_name: "rspec",
      total_count: 1,
      passed_count: status == "passed" ? 1 : 0,
      failed_count: status == "failed" ? 1 : 0,
      skipped_count: 0,
      error_count: 0
    )
    TestInsights::TestCase.create!(
      test_run: test_run,
      repository: repository,
      test_identity: identity,
      suite_name: identity.suite_name,
      name: identity.name,
      status: status,
      duration_ms: duration_ms,
      created_at: created_at,
      updated_at: created_at
    ).tap { identity.refresh_summary! }
  end

  def make_loop_case(identity:, status:, iteration:, step_state:, created_at:, workflow:)
    step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 100 + iteration,
      loop_id: "grade-loop",
      iteration: iteration,
      state: step_state,
      details: { "name" => "rspec", "required" => true }
    )
    run = step.runs.create!(
      job: workflow.job,
      trigger_kind: workflow.trigger_kind,
      state: step_state,
      iteration: iteration
    )
    test_run = TestInsights::TestRun.create!(
      run: run,
      repository: repository,
      grader_name: "rspec",
      total_count: 1,
      passed_count: status == "passed" ? 1 : 0,
      failed_count: status == "failed" ? 1 : 0,
      skipped_count: 0,
      error_count: status == "error" ? 1 : 0
    )
    TestInsights::TestCase.create!(
      test_run: test_run,
      repository: repository,
      test_identity: identity,
      suite_name: identity.suite_name,
      name: identity.name,
      status: status,
      duration_ms: 100,
      created_at: created_at,
      updated_at: created_at
    ).tap { identity.refresh_summary! }
  end

  it "returns history newest first with related run/job refs" do
    identity = make_identity
    failed = make_case(identity: identity, status: "failed", created_at: 2.minutes.ago)
    passed = make_case(identity: identity, status: "passed", created_at: 1.minute.ago)

    payload = described_class.call(user: user, test_identity_id: identity.id)

    expect(payload.dig(:test, :id)).to eq(identity.id)
    expect(payload.fetch(:history).map { |row| row.dig(:test_case, :id) }).to eq([ passed.id, failed.id ])
    expect(payload.dig(:related, :job_refs)).not_to be_empty
  end

  it "degrades a malformed history row instead of failing the whole detail payload" do
    identity = make_identity
    good = make_case(identity: identity, status: "passed", created_at: 2.minutes.ago)
    bad = make_case(identity: identity, status: "failed", created_at: 1.minute.ago)
    allow_any_instance_of(TestInsights::TestCase).to receive(:test_run) do |instance|
      raise "boom" if instance.id == bad.id

      TestInsights::TestRun.find(instance.test_run_id)
    end

    payload = described_class.call(user: user, test_identity_id: identity.id)

    rows_by_id = payload.fetch(:history).index_by { |row| row.dig(:test_case, :id) }
    expect(rows_by_id.fetch(bad.id).fetch(:error_serializing)).to include("boom")
    expect(rows_by_id.fetch(good.id)).not_to have_key(:error_serializing)
  end

  it "tags self-repaired retry-loop failures without counting them as flaky evidence" do
    identity = make_identity
    workflow = Factories.job(user: user, repository: repository).workflows.last
    failed = make_loop_case(identity: identity, status: "failed", iteration: 1, step_state: "failed", workflow: workflow, created_at: 2.minutes.ago)
    passed = make_loop_case(identity: identity, status: "passed", iteration: 2, step_state: "succeeded", workflow: workflow, created_at: 1.minute.ago)

    payload = described_class.call(user: user, test_identity_id: identity.id)

    expect(payload.dig(:test, :recent_failure_count)).to eq(0)
    expect(payload.dig(:test, :recent_pass_count)).to eq(1)
    expect(payload.dig(:test, :failure_rate)).to eq(0.0)
    expect(payload.dig(:test, :reasons)).not_to include("flaky")
    rows_by_id = payload.fetch(:history).index_by { |row| row.dig(:test_case, :id) }
    expect(rows_by_id.dig(failed.id, :test_case, :classification)).to eq("wip_repair_failure")
    expect(rows_by_id.dig(passed.id, :test_case, :classification)).to eq("scored")
  end
end
