require "rails_helper"

RSpec.describe NotificationService do
  describe ".create_for" do
    it "creates a notification for an existing user" do
      user = Factories.user
      job = Factories.job_record(user: user)

      notification = described_class.create_for(
        user: user,
        kind: "job_failed",
        job: job,
        pr_url: "https://github.com/acme/widgets/pull/1",
        body: "JOB-1 failed after repeated retries"
      )

      expect(notification).to have_attributes(
        user: user,
        kind: "job_failed",
        job: job,
        pr_url: "https://github.com/acme/widgets/pull/1",
        body: "JOB-1 failed after repeated retries"
      )
    end

    it "rejects unknown notification kinds" do
      expect {
        described_class.create_for(user: Factories.user, kind: "unknown", body: "Nope")
      }.to raise_error(ArgumentError, /unknown notification kind/)
    end

    it "short-circuits when the user does not exist" do
      user = Factories.user
      user.destroy!

      expect {
        expect(described_class.create_for(user: user, kind: "job_failed", body: "Skipped")).to be_nil
      }.not_to change(Notification, :count)
    end
  end
end
