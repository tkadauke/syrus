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

    it "publishes a chat work event to the ordinary chat that originated the Job" do
      user = Factories.user
      job = Factories.job_record(user: user)
      chat = ChatSession.create!(user: user, repository: job.repository)
      ChatProposal.create!(
        chat_session: chat,
        repository: job.repository,
        slug: "originated-job",
        title: "Originated job",
        body: "Body",
        kind: "job",
        state: "confirmed",
        job: job,
        confirmed_at: Time.current,
        filed_at: Time.current
      )
      allow(ActionCable.server).to receive(:broadcast)

      described_class.create_for(
        user: user,
        kind: "job_failed",
        job: job,
        pr_url: "https://github.com/acme/widgets/pull/1",
        body: "JOB-1 failed after repeated retries"
      )

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

  describe "chat work events" do
    let(:user) { Factories.user }
    let(:job) { Factories.job(user: user) }

    # workflow-engine-v3 B2. Most notifications report that something went
    # fine; a chat work event queue full of those buries the rare one that
    # needs a decision.
    it "publishes an event for a kind someone may have to act on" do
      expect(ChatWorkEvents).to receive(:publish!).with(hash_including(kind: "job_failed"))

      described_class.create_for(user: user, kind: "job_failed", job: job, body: "failed")
    end

    # Success completions now publish too -- the evaluator (not this
    # allowlist) decides per-event whether the chat cares about the outcome.
    it "publishes an event for widened success-completion kinds" do
      %w[job_implemented pr_merged epic_completed main_recovered].each do |kind|
        expect(ChatWorkEvents).to receive(:publish!).with(hash_including(kind: kind))

        described_class.create_for(user: user, kind: kind, job: job, body: "#{kind} happened")
      end
    end

    it "does not publish a chat work event for routine progress kinds" do
      expect(ChatWorkEvents).not_to receive(:publish!)

      described_class.create_for(user: user, kind: "pr_comment_addressed", job: job, body: "addressed")
      described_class.create_for(user: user, kind: "external_pr_feedback", job: job, body: "feedback")
    end

    # The user still sees them; they just are not chat work events.
    it "still creates the notification for a kind it does not publish" do
      expect { described_class.create_for(user: user, kind: "pr_comment_addressed", job: job, body: "addressed") }
        .to change(Notification, :count).by(1)
    end
  end
end
