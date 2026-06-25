require "rails_helper"

RSpec.describe Notification do
  it "exposes unread and recent scopes" do
    user = Factories.user
    old = described_class.create!(user: user, kind: "job_failed", body: "Old", created_at: 2.days.ago)
    read = described_class.create!(user: user, kind: "pr_merged", body: "Read", read_at: 1.hour.ago, created_at: 1.day.ago)
    fresh = described_class.create!(user: user, kind: "job_implemented", body: "Fresh", created_at: 1.hour.ago)

    expect(described_class.unread).to contain_exactly(old, fresh)
    expect(described_class.recent).to eq([ fresh, read, old ])
  end
end
