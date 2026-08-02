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
      expect(chat.messages).to be_empty
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

    it "suppresses technical notification kinds in simple mode" do
      setting = AppSetting.current
      original_mode = setting.mode
      setting.update!(mode: "simple", mode_configured_at: Time.current)
      user = Factories.user
      job = Factories.job_record(user: user, pr_number: 12, branch_name: "syrus/job-12")
      allow(ActionCable.server).to receive(:broadcast)

      %w[
        job_failed job_implemented pr_comment_addressed pr_merged epic_completed upstream_pr_closed
        main_broken main_inconclusive main_recovered
      ].each do |kind|
        expect(
          described_class.create_for(
            user: user,
            kind: kind,
            job: job,
            pr_url: "https://github.com/acme/widgets/pull/12",
            body: "Technical notification for #{job.slug} on #{job.branch_name}"
          )
        ).to be_nil
      end

      expect(Notification.count).to eq(0)
      expect(ActionCable.server).not_to have_received(:broadcast)
    ensure
      setting&.update!(mode: original_mode || "advanced")
    end

    it "strips job and PR metadata from allowed simple-mode notifications" do
      setting = AppSetting.current
      original_mode = setting.mode
      setting.update!(mode: "simple", mode_configured_at: Time.current)
      user = Factories.user
      job = Factories.job_record(user: user, pr_number: 12)
      allow(ActionCable.server).to receive(:broadcast)

      notification = described_class.create_for(
        user: user,
        kind: "epic_review_ready",
        job: job,
        pr_url: "https://github.com/acme/widgets/pull/12",
        body: "Your feature 'Checkout' is ready for your review"
      )

      expect(notification).to have_attributes(job_id: nil, pr_url: nil)
      expect(ActionCable.server).to have_received(:broadcast).with(
        AppUserChannel.broadcasting_for(user),
        hash_including(
          payload: hash_including(
            notification: hash_including(
              kind: "epic_review_ready",
              body: "Your feature 'Checkout' is ready for your review",
              job_id: nil,
              pr_url: nil
            )
          )
        )
      )
    ensure
      setting&.update!(mode: original_mode || "advanced")
    end
  end
end
