require "rails_helper"

RSpec.describe TestInsights::RuntimeSummary do
  let(:job) { Factories.job }
  let(:repository) { job.repository }
  let(:identity) do
    TestInsights::TestIdentity.create!(
      repository: repository,
      fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: "Suite", name: "example"),
      suite_name: "Suite",
      name: "example"
    )
  end

  def create_test_run!(grader_name:)
    TestInsights::TestRun.create!(
      run: job.initial_run,
      repository: repository,
      grader_name: grader_name,
      total_count: 1,
      passed_count: 1,
      failed_count: 0,
      skipped_count: 0,
      error_count: 0
    )
  end

  def create_case!(test_run:, duration_ms:, created_at:, test_identity: identity, grader_name: nil, wip_repair_failure: false)
    TestInsights::TestCase.create!(
      test_run: test_run,
      repository: repository,
      test_identity: test_identity,
      grader_name: grader_name,
      suite_name: test_identity.suite_name,
      name: test_identity.name,
      status: "passed",
      duration_ms: duration_ms,
      created_at: created_at,
      updated_at: created_at,
      wip_repair_failure: wip_repair_failure
    )
  end

  it "uses the denormalized named-grader path without joining test runs once eligible" do
    rspec = create_test_run!(grader_name: "rspec")
    3.times { |index| create_case!(test_run: rspec, grader_name: "rspec", duration_ms: 100 + index, created_at: index.minutes.ago) }

    selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      selects << sql if sql.include?("syrus_runtime_cases")
    end
    described_class.refresh_many!([ identity.id ], grader_names: [ "rspec" ])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    expect(selects).not_to be_empty
    expect(selects.join("\n")).not_to include("test_insight_runs")
  end

  it "falls back for a mixed backfill window without dropping legacy samples" do
    rspec = create_test_run!(grader_name: "rspec")
    create_case!(test_run: rspec, grader_name: nil, duration_ms: 300, created_at: 2.minutes.ago)
    create_case!(test_run: rspec, grader_name: "rspec", duration_ms: 100, created_at: 1.minute.ago)

    described_class.refresh_many!([ identity.id ], grader_names: [ "rspec" ])

    expect(described_class.find_by!(test_identity: identity, grader_name: "rspec")).to have_attributes(
      sample_count: 2,
      avg_duration_ms: 200
    )
  end

  it "preserves the exact recent-100 percentile and average values" do
    rspec = create_test_run!(grader_name: "rspec")
    101.times do |index|
      create_case!(test_run: rspec, grader_name: "rspec", duration_ms: index, created_at: index.minutes.ago)
    end

    described_class.refresh_many!([ identity.id ], grader_names: [ "rspec" ])

    summary = described_class.find_by!(test_identity: identity, grader_name: "rspec")
    expect(summary).to have_attributes(sample_count: 100, avg_duration_ms: 50, p50_duration_ms: 49, p95_duration_ms: 94)
  end

  it "keeps the all-graders row bounded to the latest 100 executions" do
    rspec = create_test_run!(grader_name: "rspec")
    jest = create_test_run!(grader_name: "jest")

    80.times { |index| create_case!(test_run: rspec, duration_ms: 1_000, created_at: (200 - index).minutes.ago) }
    80.times { |index| create_case!(test_run: jest, duration_ms: 100, created_at: (80 - index).minutes.ago) }

    described_class.refresh_many!([ identity.id ])

    expect(described_class.find_by!(test_identity: identity, grader_name: "rspec").sample_count).to eq(80)
    expect(described_class.find_by!(test_identity: identity, grader_name: "jest").sample_count).to eq(80)
    all_summary = described_class.find_by!(test_identity: identity, grader_name: described_class::ALL_GRADERS)
    expect(all_summary.sample_count).to eq(described_class::WINDOW_SIZE)
    expect(all_summary.avg_duration_ms).to eq(280)
  end

  it "uses bounded indexed probes when refreshing touched identities for one grader" do
    rspec = create_test_run!(grader_name: "rspec")
    identities = 5.times.map do |identity_index|
      test_identity = TestInsights::TestIdentity.create!(
        repository: repository,
        fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: "Suite", name: "example #{identity_index}"),
        suite_name: "Suite",
        name: "example #{identity_index}"
      )
      3.times do |case_index|
        create_case!(
          test_run: rspec,
          duration_ms: 100 + case_index,
          created_at: case_index.minutes.ago,
          test_identity: test_identity
        )
      end
      test_identity
    end

    selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      selects << sql if sql.match?(/FROM "?test_insight_cases"?/i)
    end

    described_class.refresh_many!(identities.map(&:id), grader_names: [ "rspec" ])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber

    # One batched eligibility query plus the all-grader and named-grader
    # window queries, independent of the number of pairs in the slice.
    expect(selects.size).to eq(3)
    expect(selects.join("\n")).to include("UNION ALL")
    expect(selects.join("\n")).to include("ORDER BY")
    expect(selects.join("\n")).to include("LIMIT")
    expect(selects.join("\n")).not_to match(/ROW_NUMBER\(\) OVER/i)
    expect(selects.join("\n")).not_to match(/syrus_runtime_rank/i)
    expect(selects).not_to include(match(/\bas\s+["`]?row_number["`]?\b/i))
  end

  it "plans runtime window probes through the identity-created index on SQLite" do
    skip "SQLite-specific EXPLAIN output" unless described_class.connection.adapter_name == "SQLite"

    rspec = create_test_run!(grader_name: "rspec")
    create_case!(test_run: rspec, duration_ms: 120, created_at: Time.current)

    plan = described_class.connection
      .select_rows("EXPLAIN QUERY PLAN #{described_class.send(:all_grader_duration_sql, identity.id)}")
      .flatten
      .join(" ")

    expect(plan).to include("idx_test_cases_identity_created_id")
  end

  it "does not pass unique_by to adapters without conflict-target support" do
    rspec = create_test_run!(grader_name: "rspec")
    create_case!(test_run: rspec, duration_ms: 120, created_at: Time.current)

    allow(described_class.connection).to receive(:supports_insert_conflict_target?).and_return(false)
    allow(described_class).to receive(:upsert_all).and_call_original

    described_class.refresh_many!([ identity.id ], grader_names: [ "rspec" ])

    expect(described_class).to have_received(:upsert_all).with(kind_of(Array))
  end
end
