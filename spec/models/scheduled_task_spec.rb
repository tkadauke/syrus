require "rails_helper"

RSpec.describe ScheduledTask do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def build_cron(**overrides)
    described_class.new({
      user: user,
      repository: repository,
      name: "Weekly tests",
      prompt: "Write missing tests.",
      kind: "cron",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip"
    }.merge(overrides))
  end

  def build_one_shot(**overrides)
    described_class.new({
      user: user,
      repository: repository,
      name: "Quick maintenance",
      prompt: "Bump deps.",
      kind: "one_shot",
      fire_at: 1.day.from_now,
      pr_pileup_policy: "skip"
    }.merge(overrides))
  end

  describe "validation" do
    it "is valid with reasonable cron defaults" do
      expect(build_cron).to be_valid
    end

    it "is valid for one_shot with a future fire_at" do
      expect(build_one_shot).to be_valid
    end

    it "rejects unknown kind" do
      task = build_cron(kind: "monthly")
      expect(task).not_to be_valid
    end

    it "rejects unknown pr_pileup_policy" do
      task = build_cron(pr_pileup_policy: "merge")
      expect(task).not_to be_valid
    end

    it "requires cron_expression for cron tasks" do
      task = build_cron(cron_expression: nil)
      expect(task).not_to be_valid
      expect(task.errors[:cron_expression]).to be_present
    end

    it "requires fire_at for one_shot tasks" do
      task = build_one_shot(fire_at: nil)
      expect(task).not_to be_valid
      expect(task.errors[:fire_at]).to be_present
    end

    it "rejects a cron expression that fires more than once per hour" do
      task = build_cron(cron_expression: "*/30 * * * *")
      expect(task).not_to be_valid
      expect(task.errors[:cron_expression].join).to match(/at most once per hour/)
    end

    it "rejects a malformed cron expression" do
      task = build_cron(cron_expression: "bogus")
      expect(task).not_to be_valid
    end

    it "rejects a one_shot fire_at in the past" do
      task = build_one_shot(fire_at: 1.day.ago)
      expect(task).not_to be_valid
    end
  end

  describe "minute_offset seeding" do
    it "seeds a random 0..59 offset for cron tasks at create" do
      offsets = 30.times.map { build_cron.tap(&:valid?).minute_offset }
      expect(offsets).to all(be_between(0, 59))
      expect(offsets.uniq.size).to be > 5  # extremely unlikely to collide every time
    end

    it "respects an explicitly-passed non-zero minute_offset" do
      task = build_cron(minute_offset: 17)
      task.valid?
      expect(task.minute_offset).to eq(17)
    end
  end

  describe "#smeared_cron_expression" do
    it "rewrites the minute slot to match the offset" do
      task = build_cron(cron_expression: "0 9 * * 1", minute_offset: 23)
      task.valid?
      expect(task.smeared_cron_expression).to eq("23 9 * * 1")
    end

    it "is nil for one_shot tasks" do
      expect(build_one_shot.smeared_cron_expression).to be_nil
    end
  end

  describe "#due?" do
    it "is true for an active cron task once the next scheduled time has passed" do
      # 9am Mondays UTC, force minute_offset to 0 post-create (the
      # before_validation hook randomizes it on create — and AR can't
      # distinguish "user passed 0" from "not set" because 0 is the
      # column default, so we override afterwards).
      task = build_cron(cron_expression: "0 9 * * 1")
      task.save!
      task.update_columns(minute_offset: 0)
      monday_9am = Time.utc(2026, 5, 4, 9, 0, 0)  # Mon 2026-05-04 09:00 UTC
      task.update_columns(last_fired_at: monday_9am - 1.hour, created_at: monday_9am - 1.hour)
      expect(task.due?(now: monday_9am + 1.minute)).to be true
    end

    it "is false right before the next scheduled time" do
      task = build_cron(cron_expression: "0 9 * * 1")
      task.save!
      task.update_columns(minute_offset: 0)
      monday_9am = Time.utc(2026, 5, 4, 9, 0, 0)
      task.update_columns(last_fired_at: monday_9am - 1.hour, created_at: monday_9am - 1.hour)
      expect(task.due?(now: monday_9am - 1.minute)).to be false
    end

    it "is true for one_shot tasks once fire_at has passed" do
      task = build_one_shot(fire_at: 1.minute.from_now)
      task.save!
      expect(task.due?(now: 2.minutes.from_now)).to be true
    end

    it "is false for paused tasks" do
      task = build_cron
      task.save!
      task.pause!
      expect(task.due?(now: 1.year.from_now)).to be false
    end

    it "is false for archived tasks" do
      task = build_cron
      task.save!
      task.soft_delete!
      expect(task.due?(now: 1.year.from_now)).to be false
    end

    it "is false for one_shot tasks already fired" do
      task = build_one_shot(fire_at: 1.minute.from_now)
      task.save!
      task.mark_fired_one_shot!
      expect(task.due?(now: 1.year.from_now)).to be false
    end
  end

  describe "#record_failure!" do
    it "increments consecutive_failure_count" do
      task = build_cron
      task.save!
      expect { task.record_failure! }.to change { task.reload.consecutive_failure_count }.by(1)
    end

    it "auto-pauses once the count hits AppSetting.max_job_failures" do
      task = build_cron
      task.save!
      cap = AppSetting.max_job_failures
      cap.times { task.record_failure! }
      expect(task.reload).to be_auto_paused
    end
  end

  describe "#record_success!" do
    it "stamps last_successful_fire_at and resets the failure counter" do
      task = build_cron
      task.save!
      task.update_columns(consecutive_failure_count: 5, last_successful_fire_at: nil)
      task.record_success!
      task.reload
      expect(task.consecutive_failure_count).to eq(0)
      expect(task.last_successful_fire_at).to be_present
    end
  end

  describe "soft delete" do
    it "stamps archived_at without removing the row" do
      task = build_cron
      task.save!
      expect { task.soft_delete! }.to change { task.reload.archived? }.from(false).to(true)
      expect(described_class.where(id: task.id)).to exist
    end

    it "is excluded from the .alive scope" do
      task = build_cron
      task.save!
      task.soft_delete!
      expect(described_class.alive).not_to include(task)
    end
  end

  describe "#has_open_pr?" do
    it "returns true when a prior cron Job for this task has an open PR" do
      task = build_cron
      task.save!
      task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task,
        issue_number: nil, pr_number: 99
      )
      expect(task.has_open_pr?).to be true
    end

    it "returns false when prior Jobs are closed" do
      task = build_cron
      task.save!
      job = task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task,
        issue_number: nil, pr_number: 99
      )
      job.close_with_reason!("pr_merged")
      expect(task.has_open_pr?).to be false
    end
  end

  describe "#last_pr_job" do
    let(:task) { build_cron.tap(&:save!) }

    it "returns nil when no Jobs have a pr_number" do
      task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil
      )
      expect(task.last_pr_job).to be_nil
    end

    it "returns the most recent Job with a pr_number" do
      older = task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 10
      )
      newer = task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 20
      )
      expect(task.last_pr_job).to eq(newer)
    end

    it "ignores Jobs without a pr_number when selecting the most recent" do
      pr_job = task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 10
      )
      task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil
      )
      expect(task.last_pr_job).to eq(pr_job)
    end
  end
end
