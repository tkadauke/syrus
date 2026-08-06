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
      minute_offset: 5,
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

    it "defaults auto-approval to never and accepts grader-gated modes" do
      task = build_cron
      task.save!
      expect(task.auto_approve_mode).to eq("never")

      task.update!(auto_approve_mode: "if_graders_pass")
      expect(task.auto_approve_mode).to eq("if_graders_pass")
    end

    it "rejects unknown auto-approval modes" do
      task = build_cron(auto_approve_mode: "always")
      expect(task).not_to be_valid
      expect(task.errors[:auto_approve_mode]).to be_present
    end

    it "requires a schedule for cron tasks" do
      task = build_cron(cron_expression: nil)
      expect(task).not_to be_valid
      expect(task.errors[:schedule_input]).to be_present
    end

    it "requires fire_at for one_shot tasks" do
      task = build_one_shot(fire_at: nil)
      expect(task).not_to be_valid
      expect(task.errors[:fire_at]).to be_present
    end

    it "rejects a cron expression that fires more than once per hour" do
      task = build_cron(cron_expression: "*/30 * * * *")
      expect(task).not_to be_valid
      expect(task.errors[:schedule_input].join).to include("at most once per hour")
    end

    it "rejects a malformed cron expression" do
      task = build_cron(cron_expression: "bogus")
      expect(task).not_to be_valid
    end

    it "rejects zero in day-of-month and month fields" do
      task = build_cron(cron_expression: "0 4 0 0 1")
      expect(task).not_to be_valid
      expect(task.errors[:schedule_input].join).to include("month day must be between 1 and 31")
    end

    it "rejects zero in the month field" do
      task = build_cron(cron_expression: "0 4 * 0 *")
      expect(task).not_to be_valid
      expect(task.errors.full_messages.join).to include("valid")
    end

    it "rejects zero in day-of-month lists and ranges" do
      [ "0 4 0,15 * *", "0 4 0-5 * *" ].each do |expression|
        task = build_cron(cron_expression: expression)
        expect(task).not_to be_valid
        expect(task.errors.full_messages.join).to include("valid")
      end
    end

    it "rejects the parser-invalid cron produced by replacing the minute with 49" do
      task = build_cron(cron_expression: "49 4 0 0 1")
      expect(task).not_to be_valid
      expect(task.errors.full_messages.join).to include("valid")
    end

    it "rejects a one_shot fire_at in the past" do
      task = build_one_shot(fire_at: 1.day.ago)
      expect(task).not_to be_valid
    end
  end

  describe "#hourly_cron_expression" do
    it "uses the stored cron expression without replacing the minute slot" do
      task = build_cron(cron_expression: "37 9 * * 1", minute_offset: 23)
      task.valid?
      expect(task.hourly_cron_expression).to eq("37 9 * * 1")
    end

    it "is nil for one_shot tasks" do
      expect(build_one_shot.hourly_cron_expression).to be_nil
    end

    it "seeds new cron tasks with a random minute offset when unset" do
      task = build_cron(minute_offset: nil)
      task.save!

      expect(task.minute_offset).to be_between(0, 59)
    end
  end

  describe "#due?" do
    it "is true for an active cron task once the next scheduled time has passed" do
      task = build_cron(cron_expression: "5 9 * * 1", minute_offset: 49)
      task.save!
      monday_9am = Time.utc(2026, 5, 4, 9, 0, 0)  # Mon 2026-05-04 09:00 UTC
      task.update_columns(last_fired_at: monday_9am - 1.hour, created_at: monday_9am - 1.hour)
      expect(task.due?(now: monday_9am + 6.minutes)).to be true
    end

    it "is false before the task's scheduled minute inside the scheduled hour" do
      task = build_cron(cron_expression: "5 9 * * 1", minute_offset: 49)
      task.save!
      monday_9am = Time.utc(2026, 5, 4, 9, 0, 0)
      task.update_columns(last_fired_at: monday_9am - 1.hour, created_at: monday_9am - 1.hour)
      expect(task.due?(now: monday_9am + 4.minutes)).to be false
    end

    it "is false after the task already fired in the current hourly window" do
      task = build_cron(cron_expression: "5 9 * * 1", minute_offset: 49)
      task.save!
      monday_9am = Time.utc(2026, 5, 4, 9, 0, 0)
      task.update_columns(last_fired_at: monday_9am + 5.minutes)
      expect(task.due?(now: monday_9am + 30.minutes)).to be false
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

  describe "#next_fire_at" do
    it "returns the current hourly window when it is due and has not fired" do
      task = build_cron(cron_expression: "5 9 * * 1", minute_offset: 49)
      task.save!
      monday_9am = Time.utc(2026, 5, 4, 9, 0, 0)

      expect(task.next_fire_at(from: monday_9am + 30.minutes)).to eq(monday_9am)
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

  describe "#pause!" do
    it "transitions to paused when reason is operator (default)" do
      task = build_cron
      task.save!
      task.pause!
      expect(task.reload.state).to eq("paused")
    end

    it "transitions to auto_paused when reason is auto" do
      task = build_cron
      task.save!
      task.pause!(reason: "auto")
      expect(task.reload.state).to eq("auto_paused")
    end

    it "raises on unknown reason" do
      task = build_cron
      task.save!
      expect { task.pause!(reason: "bogus") }.to raise_error(KeyError)
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
