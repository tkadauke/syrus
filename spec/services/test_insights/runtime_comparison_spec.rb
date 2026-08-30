require "rails_helper"

RSpec.describe TestInsights::RuntimeComparison do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def create_identity!(name:, suite_name: "Suite", attrs: {})
    TestIdentity.create!({
      repository: repository,
      fingerprint: TestIdentity.fingerprint_for(suite_name: suite_name, name: name),
      suite_name: suite_name,
      name: name
    }.merge(attrs))
  end

  def create_run!
    Factories.job(user: user, repository: repository).initial_run
  end

  def create_test_run!(run:, grader_name: "rspec")
    TestRun.create!(
      run: run,
      repository: repository,
      grader_name: grader_name,
      total_count: 1,
      passed_count: 1,
      failed_count: 0,
      skipped_count: 0,
      error_count: 0
    )
  end

  def create_case!(identity:, test_run:, duration_ms:, created_at: Time.current)
    TestCase.create!(
      test_run: test_run,
      repository: repository,
      test_identity: identity,
      suite_name: identity.suite_name,
      name: identity.name,
      status: "passed",
      duration_ms: duration_ms,
      created_at: created_at,
      updated_at: created_at
    )
  end

  it "compares selected identities across two runs with worker health context" do
    identity = create_identity!(name: "gets faster")
    baseline_run = create_run!
    comparison_run = create_run!
    baseline_test_run = create_test_run!(run: baseline_run)
    comparison_test_run = create_test_run!(run: comparison_run)
    create_case!(identity: identity, test_run: baseline_test_run, duration_ms: 200, created_at: 2.minutes.ago)
    create_case!(identity: identity, test_run: comparison_test_run, duration_ms: 100, created_at: 1.minute.ago)
    baseline_run.workflow.update!(worker_hostname: "worker-a")
    CommandSpan.create!(
      job: baseline_run.job,
      workflow: baseline_run.workflow,
      step: baseline_run.step,
      run: baseline_run,
      sequence: 1,
      name: "rspec",
      command_excerpt: "bundle exec rspec",
      hostname: "worker-a",
      started_at: 3.minutes.ago,
      finished_at: 2.minutes.ago,
      duration_ms: 60_000,
      outcome: "succeeded"
    )

    payload = described_class.call(
      user: user,
      repository: repository,
      test_identity_ids: [ identity.id ],
      baseline_run_id: baseline_run.id,
      comparison_run_id: comparison_run.id
    )

    test_payload = payload.fetch(:tests).sole
    expect(test_payload.dig(:baseline, :avg_duration_ms)).to eq(200)
    expect(test_payload.dig(:comparison, :avg_duration_ms)).to eq(100)
    expect(test_payload.dig(:delta, :avg_duration_ms)).to eq(ms: -100, percent: -50.0)
    expect(payload.dig(:baseline, :worker_health, :command_spans, 0, :name)).to eq("rspec")
  end

  it "compares explicit before and after windows" do
    identity = create_identity!(name: "windowed")
    run = create_run!
    test_run = create_test_run!(run: run)
    create_case!(identity: identity, test_run: test_run, duration_ms: 400, created_at: Time.zone.parse("2026-08-01T12:00:00Z"))
    create_case!(identity: identity, test_run: test_run, duration_ms: 250, created_at: Time.zone.parse("2026-08-02T12:00:00Z"))

    payload = described_class.call(
      user: user,
      repository: repository,
      test_identity_ids: [ identity.id ],
      baseline_window: { starts_at: "2026-08-01T00:00:00Z", ends_at: "2026-08-02T00:00:00Z" },
      comparison_window: { starts_at: "2026-08-02T00:00:00Z", ends_at: "2026-08-03T00:00:00Z" }
    )

    expect(payload.dig(:tests, 0, :baseline, :latest_duration_ms)).to eq(400)
    expect(payload.dig(:tests, 0, :comparison, :latest_duration_ms)).to eq(250)
  end

  it "uses runtime summaries to choose default repository-wide candidates" do
    identity = create_identity!(name: "summarized")
    TestIdentityRuntimeSummary.create!(
      repository: repository,
      test_identity: identity,
      grader_name: TestIdentityRuntimeSummary::ALL_GRADERS,
      window: TestIdentityRuntimeSummary::RECENT_100_WINDOW,
      sample_count: 3,
      avg_duration_ms: 300,
      p50_duration_ms: 250,
      p95_duration_ms: 600
    )

    test_case_selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      test_case_selects << sql if sql.match?(/FROM "?test_cases"?/i)
    end

    payload = described_class.call(
      user: user,
      repository: repository,
      baseline_window: { starts_at: 2.days.ago.iso8601, ends_at: 1.day.ago.iso8601 },
      comparison_window: { starts_at: 1.day.ago.iso8601, ends_at: Time.current.iso8601 }
    )
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber

    expect(payload.fetch(:tests).map { |test| test.dig(:test, :id) }).to eq([ identity.id ])
    expect(test_case_selects).to all(match(/"test_identity_id"|`test_identity_id`/))
  end

  it "rejects multiple baseline sources" do
    run = create_run!

    expect {
      described_class.call(
        user: user,
        repository: repository,
        baseline_run_id: run.id,
        baseline_window: { starts_at: 2.days.ago.iso8601, ends_at: 1.day.ago.iso8601 },
        comparison_window: { starts_at: 1.day.ago.iso8601, ends_at: Time.current.iso8601 }
      )
    }.to raise_error(ArgumentError, /baseline must specify exactly one/)
  end
end
