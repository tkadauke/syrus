require "rails_helper"

RSpec.describe VideoWalkthroughs::PruneJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }

  # Build a walkthrough in the given state with an attached blob, then force
  # updated_at to `age.ago` without bumping it (update_columns skips
  # timestamps/validations so the prune window + LRU order are under test
  # control). `byte_size` drives the size-sweep sum independently of the tiny
  # stubbed blob bytes.
  def walkthrough_with_blob(state:, age:, byte_size: 10, analysis: { "summary" => "s" })
    walkthrough = VideoWalkthroughs::Walkthrough.new(
      chat_session: chat,
      user: user,
      content_type: "video/webm",
      byte_size: byte_size,
      duration_seconds: 60,
      analysis: analysis
    )
    walkthrough.file.attach(io: StringIO.new("webm-bytes"), filename: "walkthrough.webm", content_type: "video/webm")
    walkthrough.save!
    # State + updated_at + byte_size set directly so a settled row can pre-date
    # the cutoff and carry a size independent of the stubbed blob.
    walkthrough.update_columns(state: state, updated_at: age.ago, byte_size: byte_size)
    walkthrough.reload
  end

  def purge_jobs_enqueued
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == ActiveStorage::PurgeJob }
  end

  before do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    # Default the size budget off so the time-sweep specs isolate the time path;
    # size-sweep specs opt into a small budget explicitly.
    AppSetting.current.update!(video_storage_budget_mb: 0)
  end

  describe "time sweep" do
    it "purges the blob (keeping the row + analysis) for a settled walkthrough past the window" do
      walkthrough = walkthrough_with_blob(state: "analyzed", age: 8.days)
      expect(walkthrough.file).to be_attached

      described_class.perform_now

      walkthrough.reload
      # Row survives with its analysis; only the attachment is purged.
      expect(VideoWalkthroughs::Walkthrough.exists?(walkthrough.id)).to be true
      expect(walkthrough.analysis).to eq({ "summary" => "s" })
      # purge_later enqueues an Active Storage purge job for the blob.
      expect(purge_jobs_enqueued).not_to be_empty
    end

    it "purges failed walkthroughs past the window too" do
      walkthrough = walkthrough_with_blob(state: "failed", age: 8.days)

      expect { described_class.perform_now }.to change {
        purge_jobs_enqueued.count
      }.by(1)

      expect(VideoWalkthroughs::Walkthrough.exists?(walkthrough.id)).to be true
    end

    it "keeps the blob for a recently settled walkthrough" do
      walkthrough = walkthrough_with_blob(state: "analyzed", age: 1.day)

      described_class.perform_now

      walkthrough.reload
      expect(walkthrough.file).to be_attached
      expect(purge_jobs_enqueued).to be_empty
    end

    it "honors a custom video_retention_days setting" do
      # A 3-day-old row is inside the default 7d window but outside a 2d one.
      AppSetting.current.update!(video_retention_days: 2)
      walkthrough = walkthrough_with_blob(state: "analyzed", age: 3.days)

      described_class.perform_now

      expect(purge_jobs_enqueued).not_to be_empty
      expect(walkthrough.reload.analysis).to eq({ "summary" => "s" })
    end

    it "never purges in-flight walkthroughs regardless of age" do
      uploaded = walkthrough_with_blob(state: "uploaded", age: 30.days, analysis: nil)
      analyzing = walkthrough_with_blob(state: "analyzing", age: 30.days, analysis: nil)

      described_class.perform_now

      [ uploaded, analyzing ].each do |walkthrough|
        walkthrough.reload
        expect(walkthrough.file).to be_attached
      end
      expect(purge_jobs_enqueued).to be_empty
    end

    it "does nothing when a settled row past the window has already been pruned" do
      walkthrough_with_blob(state: "analyzed", age: 8.days).file.purge
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear

      expect { described_class.perform_now }.not_to raise_error

      expect(purge_jobs_enqueued).to be_empty
    end

    it "never time-sweeps when retention is non-positive (destructive-cutoff guard)" do
      # AppSetting validates >= 1, but a direct DB write could set 0/negative;
      # cutoff = 0.days.ago == now would otherwise purge EVERY settled video.
      AppSetting.current.update_column(:video_retention_days, 0)
      recent = walkthrough_with_blob(state: "analyzed", age: 1.day)
      old = walkthrough_with_blob(state: "analyzed", age: 30.days)

      described_class.perform_now

      expect(purge_jobs_enqueued).to be_empty
      [ recent, old ].each { |w| expect(w.reload.file).to be_attached }
    end
  end

  describe "size sweep (LRU eviction under budget)" do
    let(:mb) { 1024 * 1024 }

    it "purges oldest-first until total stored bytes fit the budget, keeping the newest" do
      # Budget = 3MB. Four recent (inside the time window) analyzed rows at 1MB
      # each sum to 4MB → 1MB over. LRU purges the single oldest until <= budget.
      AppSetting.current.update!(video_storage_budget_mb: 3)
      oldest = walkthrough_with_blob(state: "analyzed", age: 4.days, byte_size: mb)
      older  = walkthrough_with_blob(state: "analyzed", age: 3.days, byte_size: mb)
      newer  = walkthrough_with_blob(state: "analyzed", age: 2.days, byte_size: mb)
      newest = walkthrough_with_blob(state: "analyzed", age: 1.day,  byte_size: mb)

      described_class.perform_now
      # ActiveStorage::PurgeJob is enqueued; process it so file.attached? flips.
      perform_enqueued_purges

      expect(oldest.reload.file).not_to be_attached
      [ older, newer, newest ].each do |walkthrough|
        expect(walkthrough.reload.file).to be_attached
      end
    end

    it "evicts by updated_at even when id order disagrees (LRU, not insertion order)" do
      # Regression: the eviction must key on updated_at, NOT the primary key.
      # Create the NEWEST row first so it gets the LOWEST id, and the OLDEST
      # row last (HIGHEST id) — id-asc order is now the reverse of LRU order.
      # A find_each-based sweep batches by id and would purge the newest row;
      # the correct sweep purges the oldest-updated row (highest id) first.
      AppSetting.current.update!(video_storage_budget_mb: 3)
      newest = walkthrough_with_blob(state: "analyzed", age: 1.day,  byte_size: mb)
      newer  = walkthrough_with_blob(state: "analyzed", age: 2.days, byte_size: mb)
      older  = walkthrough_with_blob(state: "analyzed", age: 3.days, byte_size: mb)
      oldest = walkthrough_with_blob(state: "analyzed", age: 4.days, byte_size: mb)
      expect(oldest.id).to be > newest.id # precondition: id order is reversed vs age

      described_class.perform_now
      perform_enqueued_purges

      expect(oldest.reload.file).not_to be_attached
      [ newest, newer, older ].each do |walkthrough|
        expect(walkthrough.reload.file).to be_attached
      end
    end

    it "evicts multiple oldest rows when a single purge is not enough" do
      # Budget = 1MB. Three 1MB rows = 3MB. Purge the two oldest to reach 1MB.
      AppSetting.current.update!(video_storage_budget_mb: 1)
      oldest = walkthrough_with_blob(state: "analyzed", age: 3.days, byte_size: mb)
      middle = walkthrough_with_blob(state: "analyzed", age: 2.days, byte_size: mb)
      newest = walkthrough_with_blob(state: "analyzed", age: 1.day,  byte_size: mb)

      described_class.perform_now
      perform_enqueued_purges

      expect(oldest.reload.file).not_to be_attached
      expect(middle.reload.file).not_to be_attached
      expect(newest.reload.file).to be_attached
    end

    it "does not purge anything when the total is under budget" do
      AppSetting.current.update!(video_storage_budget_mb: 10)
      walkthrough_with_blob(state: "analyzed", age: 2.days, byte_size: mb)
      walkthrough_with_blob(state: "analyzed", age: 1.day,  byte_size: mb)

      described_class.perform_now

      expect(purge_jobs_enqueued).to be_empty
    end

    it "is a no-op when the budget is 0 (unlimited), even far over any size" do
      AppSetting.current.update!(video_storage_budget_mb: 0)
      walkthrough_with_blob(state: "analyzed", age: 2.days, byte_size: 500 * mb)
      walkthrough_with_blob(state: "analyzed", age: 1.day,  byte_size: 500 * mb)

      described_class.perform_now

      expect(purge_jobs_enqueued).to be_empty
    end

    it "ignores in-flight rows in the size sweep budget accounting" do
      # A giant in-flight (analyzing) row must not be counted or purged; only
      # settled rows are candidates, and here the two settled rows fit budget.
      AppSetting.current.update!(video_storage_budget_mb: 5)
      analyzing = walkthrough_with_blob(state: "analyzing", age: 1.day, byte_size: 100 * mb, analysis: nil)
      settled_a = walkthrough_with_blob(state: "analyzed", age: 2.days, byte_size: mb)
      settled_b = walkthrough_with_blob(state: "analyzed", age: 1.day,  byte_size: mb)

      described_class.perform_now
      perform_enqueued_purges

      [ analyzing, settled_a, settled_b ].each do |walkthrough|
        expect(walkthrough.reload.file).to be_attached
      end
    end
  end

  # Drain enqueued ActiveStorage::PurgeJobs synchronously so file.attached?
  # reflects the purge (purge_later only enqueues; it doesn't detach inline).
  def perform_enqueued_purges
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
  end
end
