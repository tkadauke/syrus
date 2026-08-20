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
end
