require "rails_helper"

RSpec.describe UiEngagementSample do
  let(:user) { Factories.user }

  it "accepts a bounded allowlisted sample" do
    sample = described_class.new(
      user: user, route_id: "job.review", route_params: { job_id: "42" },
      started_at: 5.minutes.ago, ended_at: Time.current, active_ms: 60_000, visible_ms: 120_000
    )

    expect(sample).to be_valid
  end

  it "rejects unknown routes, subject keys, and impossible durations" do
    sample = described_class.new(
      user: user, route_id: "admin.users", route_params: { user_id: "42" },
      started_at: 1.minute.ago, ended_at: Time.current, active_ms: 70_000, visible_ms: 60_000
    )

    expect(sample).not_to be_valid
    expect(sample.errors).to include(:route_id, :active_ms)
  end
end
