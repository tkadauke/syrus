require "rails_helper"

RSpec.describe TestInsights::Query, "time filters" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  # Regression: an ISO8601 string filter used to reach SQLite unparsed and be
  # compared as TEXT against the stored datetime. Freeze just after midnight so
  # the cutoff lands on the same calendar date as the row, which is the only
  # time the two formats sort wrongly against each other.
  it "matches a same-day row when the cutoff falls on the same date" do
    travel_to Time.zone.parse("2026-09-04 00:20:00") do
      identity = TestInsights::TestIdentity.create!(
        repository: repository, fingerprint: "same-day", suite_name: "Suite", name: "needle failure",
        last_status: "failed", last_failed_at: 1.hour.ago, last_seen_at: 30.minutes.ago
      )

      result = described_class.call(
        user: user, repository_id: repository.id, category: "failing", query: "needle",
        filters: { last_failed_since: 2.days.ago.iso8601, last_seen_since: 1.day.ago.iso8601 }
      )

      expect(result.tests.map { |test| test.fetch(:id) }).to eq([ identity.id ])
    end
  end

  it "still excludes rows outside the window" do
    travel_to Time.zone.parse("2026-09-04 00:20:00") do
      TestInsights::TestIdentity.create!(
        repository: repository, fingerprint: "stale", suite_name: "Suite", name: "needle stale",
        last_status: "failed", last_failed_at: 3.days.ago, last_seen_at: 30.minutes.ago
      )

      result = described_class.call(
        user: user, repository_id: repository.id, category: "failing", query: "needle",
        filters: { last_failed_since: 2.days.ago.iso8601 }
      )

      expect(result.tests).to be_empty
    end
  end
end
