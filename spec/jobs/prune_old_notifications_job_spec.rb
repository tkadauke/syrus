require "rails_helper"

RSpec.describe PruneOldNotificationsJob do
  it "deletes only notifications older than the retention window" do
    user = Factories.user
    old = Notification.create!(user: user, kind: "job_failed", body: "Old", created_at: 31.days.ago)
    cutoff = Notification.create!(user: user, kind: "job_failed", body: "Cutoff", created_at: 30.days.ago + 1.minute)
    fresh = Notification.create!(user: user, kind: "job_failed", body: "Fresh", created_at: 29.days.ago)

    described_class.perform_now

    expect(Notification.where(id: old.id)).to be_empty
    expect(Notification.where(id: [ cutoff.id, fresh.id ])).to contain_exactly(cutoff, fresh)
  end
end
