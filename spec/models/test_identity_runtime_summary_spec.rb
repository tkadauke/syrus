require "rails_helper"

RSpec.describe TestIdentityRuntimeSummary do
  let(:job) { Factories.job }
  let(:repository) { job.repository }
  let(:identity) do
    TestIdentity.create!(
      repository: repository,
      fingerprint: TestIdentity.fingerprint_for(suite_name: "Suite", name: "example"),
      suite_name: "Suite",
      name: "example"
    )
  end

  def create_test_run!(grader_name:)
    TestRun.create!(
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

  def create_case!(test_run:, duration_ms:, created_at:)
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

  it "uses bounded bulk lookups when refreshing touched identities for one grader" do
    rspec = create_test_run!(grader_name: "rspec")
    3.times { |index| create_case!(test_run: rspec, duration_ms: 100 + index, created_at: index.minutes.ago) }

    selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      selects << sql if sql.match?(/FROM "?test_cases"?/i)
    end

    described_class.refresh_many!([ identity.id ], grader_names: [ "rspec" ])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber

    expect(selects.size).to be <= 2
    expect(selects).to all(match(/syrus_runtime_rank/i))
    expect(selects).not_to include(match(/\bas\s+["`]?row_number["`]?\b/i))
  end
end
