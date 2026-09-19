require "rails_helper"

RSpec.describe NotificationService do
  after do
    Feature.clear_enabled_cache!("admin_supervisor_chat")
  end

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
        hash_including(
          type: "notification_created",
          unread_count: 1,
          payload: hash_including(
            unread_count: 1,
            notification: hash_including(
              kind: "job_failed",
              body: "JOB-1 failed after repeated retries"
            )
          )
        )
      )
    end

    it "publishes a supervisor event when supervisor chat is enabled" do
      feature = Feature.find_or_create_by!(slug: "admin_supervisor_chat") do |record|
        record.category = "Operations"
        record.name = "Admin supervisor chat"
      end
      feature.update!(enabled: true)
      Feature.clear_enabled_cache!("admin_supervisor_chat")

      admin = Factories.user(admin: true)
      user = Factories.user
      job = Factories.job_record(user: user)
      allow(ActionCable.server).to receive(:broadcast)
      allow(AppEvents).to receive(:broadcast)

      described_class.create_for(
        user: user,
        kind: "job_failed",
        job: job,
        pr_url: "https://github.com/acme/widgets/pull/1",
        body: "JOB-1 failed after repeated retries"
      )

      chat = admin.chat_sessions.find_by!(system_kind: "supervisor")
      event = chat.scoped_events.last
      expect(event.payload).to include(
        "kind" => "job_failed",
        "severity" => "critical",
        "summary" => "JOB-1 failed after repeated retries"
      )
      expect(event.payload["details"]).to include(
        "notification_kind" => "job_failed",
        "job_id" => job.id,
        "pr_url" => "https://github.com/acme/widgets/pull/1"
      )
      expect(chat.messages.pluck(:role)).to eq([ "user" ])
      expect(chat.messages.first.content).to include(
        "source" => "supervisor_kickoff",
        "text" => include("Supervisor operations triage")
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

  describe "supervisor events" do
    let(:user) { Factories.user }
    let(:job) { Factories.job(user: user) }

    # workflow-engine-v3 B2. Most notifications report that something went
    # fine; a supervisor queue full of those buries the rare one that needs a
    # decision.
    it "publishes an event for a kind someone may have to act on" do
      expect(SupervisorEvents).to receive(:publish!).with(hash_including(kind: "job_failed"))

      described_class.create_for(user: user, kind: "job_failed", job: job, body: "failed")
    end

    it "does not wake the supervisor for routine good news" do
      expect(SupervisorEvents).not_to receive(:publish!)

      described_class.create_for(user: user, kind: "pr_merged", job: job, body: "merged")
      described_class.create_for(user: user, kind: "job_implemented", job: job, body: "done")
      described_class.create_for(user: user, kind: "main_recovered", job: job, body: "recovered")
    end

    # The user still sees them; they just are not supervisor events.
    it "still creates the notification for a kind it does not publish" do
      expect { described_class.create_for(user: user, kind: "pr_merged", job: job, body: "merged") }
        .to change(Notification, :count).by(1)
    end
  end
end
