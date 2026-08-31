require "rails_helper"

RSpec.describe TestInsights::Query do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def create_identity!(name:, suite_name: "Suite", repo: repository, attrs: {})
    TestIdentity.create!({
      repository: repo,
      fingerprint: TestIdentity.fingerprint_for(suite_name: suite_name, name: name),
      suite_name: suite_name,
      name: name
    }.merge(attrs))
  end

  def create_case!(identity:, status:, created_at:, duration_ms: 100)
    run = Factories.job(user: identity.repository.user, repository: identity.repository).initial_run
    test_run = TestRun.create!(
      run: run,
      repository: identity.repository,
      grader_name: "rspec",
      total_count: 1,
      passed_count: status == "passed" ? 1 : 0,
      failed_count: status == "failed" ? 1 : 0,
      skipped_count: 0,
      error_count: status == "error" ? 1 : 0
    )

    TestCase.create!(
      test_run: test_run,
      repository: identity.repository,
      test_identity: identity,
      suite_name: identity.suite_name,
      name: identity.name,
      status: status,
      duration_ms: duration_ms,
      created_at: created_at,
      updated_at: created_at
    ).tap { identity.refresh_summary! }
  end

  it "resolves repositories by id through the user's access scope" do
    owned = create_identity!(name: "owned", attrs: { last_seen_at: 1.minute.ago })
    other_repo = Factories.repository(owner: "other", name: "private")
    create_identity!(name: "private", repo: other_repo, attrs: { last_seen_at: Time.current })

    result = described_class.call(user: user, repository_id: repository.id)

    expect(result.repository).to eq(repository)
    expect(result.tests.map { |test| test.fetch(:id) }).to eq([ owned.id ])
  end

  it "resolves repositories by owner/name slug for repository members" do
    collaborator = Factories.user(email_address: "collab@example.com")
    repository.repository_memberships.create!(user: collaborator, role: "read")
    create_identity!(name: "member-visible", attrs: { last_seen_at: 1.minute.ago })

    result = described_class.call(user: collaborator, repository_slug: "acme/widgets")

    expect(result.repository).to eq(repository)
    expect(result.tests.first.fetch(:name)).to eq("member-visible")
  end

  it "raises not found for repositories outside the user's access scope" do
    outsider = Factories.user(email_address: "outsider@example.com")

    expect {
      described_class.call(user: outsider, repository_slug: "acme/widgets")
    }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "sorts slow tests by latest duration using test identity summaries" do
    faster = create_identity!(name: "fast enough", attrs: { last_duration_ms: 1_500, last_seen_at: 3.minutes.ago })
    slower = create_identity!(name: "slowest", attrs: { last_duration_ms: 4_000, last_seen_at: 2.minutes.ago })
    create_identity!(name: "quick", attrs: { last_duration_ms: 50, last_seen_at: 1.minute.ago })

    result = described_class.call(
      user: user,
      repository: repository,
      category: "slow",
      sort: "last_duration",
      direction: "desc"
    )

    expect(result.tests.map { |test| test.fetch(:id) }).to eq([ slower.id, faster.id ])
  end

  it "sorts repository-wide slow tests by persisted p95 runtime summaries" do
    fast = create_identity!(name: "fast", attrs: { last_seen_at: 2.minutes.ago })
    slow = create_identity!(name: "slow", attrs: { last_seen_at: 1.minute.ago })
    TestIdentityRuntimeSummary.create!(
      repository: repository,
      test_identity: fast,
      grader_name: TestIdentityRuntimeSummary::ALL_GRADERS,
      window: TestIdentityRuntimeSummary::RECENT_100_WINDOW,
      sample_count: 8,
      avg_duration_ms: 200,
      p50_duration_ms: 180,
      p95_duration_ms: 300,
      min_duration_ms: 100,
      max_duration_ms: 320,
      last_observed_at: 2.minutes.ago
    )
    TestIdentityRuntimeSummary.create!(
      repository: repository,
      test_identity: slow,
      grader_name: TestIdentityRuntimeSummary::ALL_GRADERS,
      window: TestIdentityRuntimeSummary::RECENT_100_WINDOW,
      sample_count: 8,
      avg_duration_ms: 1_400,
      p50_duration_ms: 1_200,
      p95_duration_ms: 2_500,
      min_duration_ms: 800,
      max_duration_ms: 2_700,
      last_observed_at: 1.minute.ago
    )

    result = described_class.call(
      user: user,
      repository: repository,
      sort: "p95_duration",
      direction: "desc"
    )

    expect(result.summary_window).to eq(TestIdentityRuntimeSummary::RECENT_100_WINDOW)
    expect(result.tests.map { |test| test.fetch(:id) }).to eq([ slow.id, fast.id ])
    expect(result.tests.first.fetch(:runtime_summary)).to include(
      sample_count: 8,
      avg_duration_ms: 1_400,
      p50_duration_ms: 1_200,
      p95_duration_ms: 2_500
    )
  end

  it "filters by text query, last_failed, and last_seen summary columns" do
    matching = create_identity!(
      name: "needle failure",
      attrs: { last_status: "failed", last_failed_at: 1.hour.ago, last_seen_at: 30.minutes.ago }
    )
    create_identity!(
      name: "needle stale",
      attrs: { last_status: "failed", last_failed_at: 3.days.ago, last_seen_at: 30.minutes.ago }
    )
    create_identity!(
      name: "other failure",
      attrs: { last_status: "failed", last_failed_at: 1.hour.ago, last_seen_at: 3.days.ago }
    )

    result = described_class.call(
      user: user,
      repository_id: repository.id,
      category: "failing",
      query: "needle",
      filters: {
        last_failed_since: 2.days.ago.iso8601,
        last_seen_since: 1.day.ago.iso8601
      }
    )

    expect(result.tests.map { |test| test.fetch(:id) }).to eq([ matching.id ])
  end

  it "sorts and filters by bounded recent failure rate" do
    always_failing = create_identity!(name: "always failing", attrs: { last_failed_at: 1.minute.ago, last_seen_at: 1.minute.ago })
    flaky = create_identity!(name: "sometimes failing", attrs: { last_failed_at: 2.minutes.ago, last_passed_at: 1.minute.ago, last_seen_at: 1.minute.ago })
    passing = create_identity!(name: "passing", attrs: { last_seen_at: 1.minute.ago })

    create_case!(identity: always_failing, status: "failed", created_at: 3.minutes.ago)
    create_case!(identity: always_failing, status: "error", created_at: 2.minutes.ago)
    create_case!(identity: flaky, status: "failed", created_at: 3.minutes.ago)
    create_case!(identity: flaky, status: "passed", created_at: 2.minutes.ago)
    create_case!(identity: passing, status: "passed", created_at: 2.minutes.ago)

    result = described_class.call(
      user: user,
      repository_id: repository.id,
      category: "recently_seen",
      sort: "failure_rate",
      filters: { min_failure_rate: 0.5 }
    )

    expect(result.tests.map { |test| test.fetch(:name) }).to eq([ "always failing", "sometimes failing" ])
    expect(result.tests.map { |test| test.fetch(:failure_rate) }).to eq([ 1.0, 0.5 ])
  end

  it "falls back to the default lookback for malformed lookback filters" do
    identity = create_identity!(name: "malformed lookback", attrs: { last_seen_at: 1.minute.ago })
    create_case!(identity: identity, status: "failed", created_at: 2.minutes.ago)

    [ "abc", nil ].each do |lookback|
      result = described_class.call(
        user: user,
        repository_id: repository.id,
        filters: { lookback: lookback }
      )

      expect(result.tests.first.fetch(:name)).to eq("malformed lookback")
      expect(result.tests.first.fetch(:failed_count)).to eq(1)
    end
  end

  it "batch-loads recent stats for failure-rate sorting" do
    6.times do |index|
      identity = create_identity!(
        name: "candidate #{index}",
        attrs: { last_failed_at: index.minutes.ago, last_seen_at: index.minutes.ago }
      )
      create_case!(identity: identity, status: "failed", created_at: 2.minutes.ago)
      create_case!(identity: identity, status: "passed", created_at: 1.minute.ago)
    end

    test_case_selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      test_case_selects << sql if sql.match?(/FROM "?test_cases"?/i)
    end

    result = described_class.call(
      user: user,
      repository_id: repository.id,
      category: "recently_seen",
      sort: "failure_rate",
      limit: 6
    )
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber

    expect(result.tests.size).to eq(6)
    expect(test_case_selects.size).to be <= 4
    # Assert on each batch loader's own window-function alias rather than
    # counting ROW_NUMBER globally: several unrelated readers rank test_cases
    # the same way, so a global count silently turns into a tripwire for code
    # that has nothing to do with this query's batching.
    expect(test_case_selects.count { |sql| sql.include?("syrus_recent_rank") }).to eq(1)
    expect(test_case_selects.count { |sql| sql.include?("syrus_latest_case_rank") }).to eq(1)
  end

  it "clamps limits and returns stable ids and links for related records" do
    identity = create_identity!(name: "linked", attrs: { last_seen_at: Time.current })
    test_case = create_case!(identity: identity, status: "failed", created_at: 1.minute.ago, duration_ms: 250)

    result = described_class.call(user: user, repository: repository, limit: 1_000)
    test = result.tests.first

    expect(result.limit).to eq(described_class::MAX_LIMIT)
    expected_path = Rails.application.routes.url_helpers.repository_path(repository, tab: "tests", test_id: identity.id)
    expect(test.fetch(:links).fetch(:app_path)).to eq(expected_path)
    expect(test.dig(:latest, :test_case, :id)).to eq(test_case.id)
    expect(test.dig(:latest, :test_run, :id)).to eq(test_case.test_run_id)
    expect(test.dig(:latest, :run, :slug)).to eq("RUN-#{test_case.test_run.run_id}")
    expect(test.dig(:latest, :job, :slug)).to eq(test_case.test_run.run.job.slug)
  end

  it "does not query test_cases while choosing repository-wide candidates" do
    create_identity!(name: "failed", attrs: { last_status: "failed", last_failed_at: 1.minute.ago, last_seen_at: 1.minute.ago })

    sql_before_test_case_lookup = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      next unless sql.match?(/FROM "?test_cases"?/i)

      sql_before_test_case_lookup << sql
    end

    described_class.call(user: user, repository: repository, category: "failing", sort: "last_failed")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber

    expect(sql_before_test_case_lookup).to all(match(/"test_identity_id"|`test_identity_id`/))
  end

  it "does not scan repository-wide test cases for p95 runtime rankings" do
    identity = create_identity!(name: "summarized", attrs: { last_seen_at: 1.minute.ago })
    TestIdentityRuntimeSummary.create!(
      repository: repository,
      test_identity: identity,
      grader_name: TestIdentityRuntimeSummary::ALL_GRADERS,
      window: TestIdentityRuntimeSummary::RECENT_100_WINDOW,
      sample_count: 3,
      avg_duration_ms: 200,
      p50_duration_ms: 180,
      p95_duration_ms: 300
    )

    test_case_selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      test_case_selects << sql if sql.match?(/FROM "?test_cases"?/i)
    end

    described_class.call(user: user, repository: repository, sort: "p95_duration", direction: "desc")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber

    expect(test_case_selects).to all(match(/"test_identity_id"|`test_identity_id`/))
  end

  it "uses the summary join instead of raw case filtering for grader-scoped p95 rankings" do
    identity = create_identity!(name: "jest summarized", attrs: { last_seen_at: 1.minute.ago })
    TestIdentityRuntimeSummary.create!(
      repository: repository,
      test_identity: identity,
      grader_name: "jest",
      window: TestIdentityRuntimeSummary::RECENT_100_WINDOW,
      sample_count: 3,
      avg_duration_ms: 200,
      p50_duration_ms: 180,
      p95_duration_ms: 300
    )

    test_case_selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      test_case_selects << sql if sql.match?(/FROM "?test_cases"?/i)
    end

    result = described_class.call(user: user, repository: repository, grader_name: "jest", sort: "p95_duration", direction: "desc")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber

    expect(result.tests.map { |test| test.fetch(:id) }).to eq([ identity.id ])
    expect(test_case_selects).to all(match(/"test_identity_id"|`test_identity_id`/))
  end
end
