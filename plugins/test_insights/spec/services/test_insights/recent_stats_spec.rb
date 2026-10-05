require "rails_helper"

RSpec.describe TestInsights::RecentStats do
  let(:repository) { Factories.repository }

  def create_identity!(name)
    TestInsights::TestIdentity.create!(
      repository: repository,
      fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: "Suite", name: name),
      suite_name: "Suite",
      name: name
    )
  end

  def create_test_case!(identity, status:, created_at:, duration_ms: 100, wip_repair_failure: false)
    test_run = TestInsights::TestRun.create!(
      run: Factories.job(repository: repository).initial_run,
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
      duration_ms: duration_ms,
      wip_repair_failure: wip_repair_failure,
      created_at: created_at,
      updated_at: created_at
    )
  end

  it "loads bounded recent stats per identity without a window-function batch scan" do
    first = create_identity!("first")
    second = create_identity!("second")
    create_test_case!(first, status: "failed", created_at: 4.minutes.ago, duration_ms: 400)
    create_test_case!(first, status: "passed", created_at: 3.minutes.ago, duration_ms: 200)
    create_test_case!(first, status: "error", created_at: 2.minutes.ago, duration_ms: 100, wip_repair_failure: true)
    create_test_case!(second, status: "passed", created_at: 1.minute.ago, duration_ms: 50)
    allow(TestInsights::TestCase).to receive(:scored_created_index_hint).and_return(" /* scored-created-index */")

    test_case_selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      test_case_selects << sql if sql.match?(/FROM [`"]?test_insight_cases[`"]?/i)
    end

    stats = described_class.load([ first, second ], lookback: 2)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber

    expect(stats.fetch(first.id)).to include(
      total_count: 2,
      failed_count: 1,
      passed_count: 1,
      failure_rate: 0.5,
      avg_duration_ms: 300
    )
    expect(stats.fetch(second.id)).to include(
      total_count: 1,
      failed_count: 0,
      passed_count: 1,
      failure_rate: 0.0,
      avg_duration_ms: 50
    )
    sql = test_case_selects.join("\n")
    expect(sql).to include("scored-created-index")
    expect(sql).to include("UNION ALL")
    expect(sql).to include("ORDER BY")
    expect(sql).to include("LIMIT")
    expect(sql).not_to include("ROW_NUMBER() OVER")
    expect(sql).not_to include("syrus_recent_rank")
  end
end
