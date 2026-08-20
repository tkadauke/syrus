require "rails_helper"

RSpec.describe TestIdentity do
  describe ".ensure_for_cases!" do
    let(:repository) { Factories.repository }
    let(:test_case) do
      TestCase.new(
        repository: repository,
        suite_name: "MySpec",
        name: "does the thing",
        status: "passed"
      )
    end

    it "uses adapter-portable inserts for missing identities" do
      allow(described_class).to receive(:insert_all).and_call_original

      described_class.ensure_for_cases!(repository: repository, cases: [ test_case ])

      expect(described_class).to have_received(:insert_all) do |_rows, **options|
        expect(options).to be_empty
      end
    end
  end

  describe ".interesting_for_repository" do
    let(:repository) { Factories.repository }

    def create_identity!(name:, attrs: {})
      described_class.create!({
        repository: repository,
        fingerprint: described_class.fingerprint_for(suite_name: "Suite", name: name),
        suite_name: "Suite",
        name: name
      }.merge(attrs))
    end

    it "uses test identity summaries instead of scanning test cases" do
      failed = create_identity!(name: "failed", attrs: { last_failed_at: 2.minutes.ago, last_seen_at: 2.minutes.ago })
      flaky = create_identity!(name: "flaky", attrs: { last_failed_at: 3.minutes.ago, last_passed_at: 1.minute.ago, last_seen_at: 1.minute.ago })
      slow = create_identity!(name: "slow", attrs: { last_duration_ms: 5_000, last_seen_at: 4.minutes.ago })

      expect(TestCase).not_to receive(:where)

      expect(described_class.interesting_for_repository(repository, limit: 10)).to eq([ failed, flaky, slow ])
    end
  end

  describe ".refresh_many!" do
    let(:repository) { Factories.repository }

    def create_identity!(name)
      described_class.create!(
        repository: repository,
        fingerprint: described_class.fingerprint_for(suite_name: "Suite", name: name),
        suite_name: "Suite",
        name: name
      )
    end

    def create_test_case!(identity, status:, created_at:)
      test_run = TestRun.create!(
        run: Factories.job(repository: repository).initial_run,
        repository: repository,
        grader_name: "rspec",
        total_count: 1,
        passed_count: status == "passed" ? 1 : 0,
        failed_count: status == "failed" ? 1 : 0,
        skipped_count: 0,
        error_count: status == "error" ? 1 : 0
      )
      TestCase.create!(
        test_run: test_run,
        repository: repository,
        test_identity: identity,
        suite_name: identity.suite_name,
        name: identity.name,
        status: status,
        duration_ms: 123,
        created_at: created_at,
        updated_at: created_at
      )
    end

    it "refreshes many identity summaries with bounded test case reads" do
      identities = 4.times.map { |index| create_identity!("case #{index}") }
      identities.each_with_index do |identity, index|
        create_test_case!(identity, status: "failed", created_at: (10 - index).minutes.ago)
        create_test_case!(identity, status: "passed", created_at: (5 - index).minutes.ago)
      end

      test_case_selects = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
        sql = payload[:sql].to_s
        test_case_selects << sql if sql.match?(/\ASELECT .*FROM "?test_cases"?/i)
      end

      described_class.refresh_many!(identities.map(&:id))
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber

      expect(test_case_selects.size).to be <= 3
      expect(identities.first.reload).to have_attributes(
        last_status: "passed",
        last_duration_ms: 123
      )
      expect(identities.first.last_failed_at).to be_present
      expect(identities.first.last_passed_at).to be_present
    end
  end
end
