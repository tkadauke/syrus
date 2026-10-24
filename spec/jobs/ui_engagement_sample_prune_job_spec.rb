require "rails_helper"

RSpec.describe UiEngagementSamplePruneJob do
  it "deletes only samples older than 90 days" do
    user = Factories.user
    attributes = { user: user, route_id: "job.show", route_params: { job_id: "1" }, active_ms: 1, visible_ms: 1 }
    old = UiEngagementSample.create!(**attributes, started_at: 91.days.ago, ended_at: 91.days.ago + 1.second)
    fresh = UiEngagementSample.create!(**attributes, started_at: 89.days.ago, ended_at: 89.days.ago + 1.second)

    described_class.perform_now

    expect(UiEngagementSample.exists?(old.id)).to be(false)
    expect(UiEngagementSample.exists?(fresh.id)).to be(true)
  end
end
