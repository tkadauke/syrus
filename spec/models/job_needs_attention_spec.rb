require "rails_helper"

RSpec.describe JobNeedsAttention do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  before { clear_enqueued_jobs }

  describe "#set_needs_attention!" do
    it "marks the job as needing attention with the given reason" do
      job.set_needs_attention!(reason: "upstream_pr_closed")

      expect(job.needs_attention?).to be true
      expect(job.needs_attention_reason).to eq("upstream_pr_closed")
    end

    it "records needs_attention_since on first set" do
      freeze_time do
        job.set_needs_attention!(reason: "upstream_pr_closed")
        expect(job.needs_attention_since).to be_within(1.second).of(Time.current)
      end
    end

    it "preserves the original needs_attention_since when called again" do
      original_since = 2.days.ago
      job.update!(
        needs_attention: true,
        needs_attention_reason: "upstream_pr_closed",
        needs_attention_since: original_since
      )

      job.set_needs_attention!(reason: "upstream_pr_closed")

      expect(job.reload.needs_attention_since).to be_within(1.second).of(original_since)
    end

    it "persists the changes to the database" do
      job.set_needs_attention!(reason: "fork_pr_closed")

      reloaded = job.reload
      expect(reloaded.needs_attention?).to be true
      expect(reloaded.needs_attention_reason).to eq("fork_pr_closed")
    end
  end

  describe "#clear_needs_attention!" do
    before do
      job.update!(
        needs_attention: true,
        needs_attention_reason: "upstream_pr_closed",
        needs_attention_since: 1.day.ago
      )
    end

    it "clears the attention flags" do
      job.clear_needs_attention!

      reloaded = job.reload
      expect(reloaded.needs_attention?).to be false
      expect(reloaded.needs_attention_reason).to be_nil
      expect(reloaded.needs_attention_since).to be_nil
    end

    it "is a no-op when the job does not need attention" do
      job.update!(needs_attention: false, needs_attention_reason: nil, needs_attention_since: nil)

      expect { job.clear_needs_attention! }.not_to(change { job.reload.updated_at })
    end
  end

  describe "#start_grace_period!" do
    it "sets grace_period_expires_at to now + duration" do
      freeze_time do
        job.start_grace_period!(duration: 3.days)
        expect(job.grace_period_expires_at).to be_within(1.second).of(3.days.from_now)
      end
    end

    it "persists grace_period_expires_at to the database" do
      job.start_grace_period!(duration: 1.day)
      expect(job.reload.grace_period_expires_at).to be_present
    end

    it "enqueues a GracePeriodExpiryJob scheduled at the expiry time" do
      freeze_time do
        job.start_grace_period!(duration: 2.days)
        expect(GracePeriodExpiryJob).to have_been_enqueued
          .with(job.id)
          .at(2.days.from_now)
      end
    end
  end

  describe "#cancel_grace_period!" do
    it "clears grace_period_expires_at" do
      job.update!(grace_period_expires_at: 12.hours.from_now)

      job.cancel_grace_period!

      expect(job.reload.grace_period_expires_at).to be_nil
    end

    it "is a no-op when grace_period_expires_at is already nil" do
      job.update!(grace_period_expires_at: nil)

      expect { job.cancel_grace_period! }.not_to(change { job.reload.updated_at })
    end
  end

  describe "#in_grace_period?" do
    it "returns true when grace_period_expires_at is in the future" do
      job.grace_period_expires_at = 1.hour.from_now
      expect(job.in_grace_period?).to be true
    end

    it "returns false when grace_period_expires_at is in the past" do
      job.grace_period_expires_at = 1.hour.ago
      expect(job.in_grace_period?).to be false
    end

    it "returns false when grace_period_expires_at is nil" do
      job.grace_period_expires_at = nil
      expect(job.in_grace_period?).to be false
    end
  end

  describe "#grace_period_expired?" do
    it "returns true when grace_period_expires_at is in the past" do
      job.grace_period_expires_at = 1.second.ago
      expect(job.grace_period_expired?).to be true
    end

    it "returns false when grace_period_expires_at is in the future" do
      job.grace_period_expires_at = 1.second.from_now
      expect(job.grace_period_expired?).to be false
    end

    it "returns false when grace_period_expires_at is nil" do
      job.grace_period_expires_at = nil
      expect(job.grace_period_expired?).to be false
    end
  end
end
