require "rails_helper"
require Rails.root.join("db/migrate/20261114160942_rearm_auto_paused_journaling_schedules")

RSpec.describe RearmAutoPausedJournalingSchedules do
  it "idempotently re-arms only auto-paused journaling schedules" do
    user = Factories.user
    repository = Factories.repository(user: user)
    attributes = {
      user:, repository:, name: "System task", kind: "cron", schedule_input: "Every day at 9:00 AM",
      pr_pileup_policy: "skip", prompt: nil, consecutive_failure_count: 3
    }
    journaling = ScheduledTasks::Task.create!(**attributes, coworker_id: 101, system_key: "journaling")
    owner_paused = ScheduledTasks::Task.create!(**attributes, coworker_id: 102, system_key: "journaling")
    other_system = ScheduledTasks::Task.create!(**attributes, coworker_id: 103, system_key: "other")
    journaling.update_columns(state: "auto_paused")
    owner_paused.update_columns(state: "paused")
    other_system.update_columns(state: "auto_paused")

    2.times { ActiveRecord::Migration.suppress_messages { described_class.new.up } }

    expect(journaling.reload).to have_attributes(state: "scheduled", consecutive_failure_count: 0)
    expect(owner_paused.reload).to have_attributes(state: "paused", consecutive_failure_count: 3)
    expect(other_system.reload).to have_attributes(state: "auto_paused", consecutive_failure_count: 3)
  end
end
