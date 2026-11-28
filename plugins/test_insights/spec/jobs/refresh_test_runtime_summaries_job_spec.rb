require "rails_helper"

RSpec.describe RefreshTestRuntimeSummariesJob do
  it "refreshes the requested identities for the grader" do
    allow(TestInsights::RuntimeSummary).to receive(:refresh_many!)

    described_class.perform_now([ 3, 3, 7 ], "rspec")

    expect(TestInsights::RuntimeSummary).to have_received(:refresh_many!)
      .with([ 3, 7 ], grader_names: [ "rspec" ])
  end

  it "does nothing without identities" do
    allow(TestInsights::RuntimeSummary).to receive(:refresh_many!)

    described_class.perform_now([], "rspec")

    expect(TestInsights::RuntimeSummary).not_to have_received(:refresh_many!)
  end

  # Recomputing every identity's 100-sample window after every grader run
  # was the largest consumer of production MySQL time; one more sample barely
  # moves the window, so recently refreshed identities are skipped.
  describe "refresh throttling" do
    let(:job) { Factories.job }
    let(:repository) { job.repository }

    def identity!(name)
      TestInsights::TestIdentity.create!(
        repository: repository,
        fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: "Suite", name: name),
        suite_name: "Suite",
        name: name
      )
    end

    def summary!(identity, grader_name, updated_at)
      TestInsights::RuntimeSummary.create!(
        repository: repository, test_identity: identity, grader_name: grader_name,
        window: TestInsights::RuntimeSummary::RECENT_100_WINDOW, sample_count: 1, avg_duration_ms: 10,
        p50_duration_ms: 10, p95_duration_ms: 10, min_duration_ms: 10, max_duration_ms: 10,
        created_at: updated_at, updated_at: updated_at
      )
    end

    it "skips identities whose grader and all-grader summaries are fresh" do
      all = TestInsights::RuntimeSummary::ALL_GRADERS
      fresh = identity!("fresh")
      stale = identity!("stale")
      partial = identity!("partial")
      unseen = identity!("unseen")
      summary!(fresh, "rspec", 1.hour.ago)
      summary!(fresh, all, 1.hour.ago)
      summary!(stale, "rspec", 7.hours.ago)
      summary!(stale, all, 1.hour.ago)
      summary!(partial, all, 1.hour.ago)
      allow(TestInsights::RuntimeSummary).to receive(:refresh_many!)

      described_class.perform_now([ fresh.id, stale.id, partial.id, unseen.id ], "rspec")

      expect(TestInsights::RuntimeSummary).to have_received(:refresh_many!)
        .with([ stale.id, partial.id, unseen.id ], grader_names: [ "rspec" ])
    end

    it "does not refresh at all when every identity is fresh" do
      identity = identity!("fresh")
      summary!(identity, "rspec", 5.minutes.ago)
      summary!(identity, TestInsights::RuntimeSummary::ALL_GRADERS, 5.minutes.ago)
      allow(TestInsights::RuntimeSummary).to receive(:refresh_many!)

      described_class.perform_now([ identity.id ], "rspec")

      expect(TestInsights::RuntimeSummary).not_to have_received(:refresh_many!)
    end
  end
end
