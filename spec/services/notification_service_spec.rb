require "rails_helper"

RSpec.describe NotificationService do
  describe ".create_for" do
    it "creates a notification for an existing user" do
      user = Factories.user
      job = Factories.job_record(user: user)

      allow(ActionCable.server).to receive(:broadcast)

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
      expect(ActionCable.server).to have_received(:broadcast).with(
        AppUserChannel.broadcasting_for(user),
        { type: "notification_created", unread_count: 1 }
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
      allow(ActionCable.server).to receive(:broadcast)

      expect {
        expect(described_class.create_for(user: user, kind: "job_failed", body: "Skipped")).to be_nil
      }.not_to change(Notification, :count)
      expect(ActionCable.server).not_to have_received(:broadcast)
    end

    it "skips notification creation when the user disabled that kind" do
      user = Factories.user(notification_preferences: { "job_failed" => false })
      allow(ActionCable.server).to receive(:broadcast)

      expect {
        expect(described_class.create_for(user: user, kind: "job_failed", body: "Skipped")).to be_nil
      }.not_to change(Notification, :count)
      expect(ActionCable.server).not_to have_received(:broadcast)
    end
  end
end
