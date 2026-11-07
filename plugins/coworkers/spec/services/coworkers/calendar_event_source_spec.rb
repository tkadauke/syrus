require "rails_helper"

RSpec.describe Coworkers::CalendarEventSource do
  include WorkUnitsSpecHelpers
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-calendar",
      workspace_repo: repository.remote_url, avatar_key: "comet", accent_hex: "#b6492e")
  end
  let(:main_chat) { ChatSession.create!(user: owner, repository:, title: "Maya") }

  def task(**attributes)
    ScheduledTasks::Task.create!({
      user: owner, repository:, coworker_id: coworker.id, name: "Morning briefing",
      prompt: "Prepare the briefing.", kind: "cron", cron_expression: "0 9 * * *",
      schedule_timezone: "UTC", pr_pileup_policy: "skip", after_run: "wake"
    }.merge(attributes))
  end

  def events(starts_at:, ends_at:, user: owner)
    described_class.calendar_events(user:, starts_at:, ends_at:)
  end

  before { Coworkers::Chat.create!(coworker:, chat_session: main_chat, role: "main") }

  it "presents owner-authorized coworker occurrences with identity and destinations" do
    scheduled = task
    starts_at = 1.day.from_now.beginning_of_day

    event = events(starts_at:, ends_at: starts_at + 1.day).sole

    expect(event).to include(source_id: "coworkers:scheduled_work", kind: "coworker_scheduled_task",
      state: "planned", destination_path: "/coworkers/#{coworker.id}")
    expect(event.fetch(:metadata)).to include(
      coworker_id: coworker.id, coworker_name: "Maya", coworker_handle: "maya-calendar",
      coworker_avatar_key: "comet", coworker_accent_hex: "#b6492e",
      coworker_path: "/coworkers/#{coworker.id}", main_chat_path: "/chats/#{main_chat.id}",
      scheduled_task_id: scheduled.id, scheduled_task_path: "/coworkers/#{coworker.id}?tab=schedules",
      after_run: "wake", system_schedule: false
    )
  end

  it "does not expose another owner's coworker even through a shared repository" do
    task
    other = Factories.user
    repository.repository_memberships.create!(user: other, role: "read")
    starts_at = 1.day.from_now.beginning_of_day

    expect(events(user: other, starts_at:, ends_at: starts_at + 1.day)).to be_empty
  end

  it "identifies code-owned system schedules" do
    scheduled = task(after_run: "quiet")
    scheduled.update_columns(system_key: Coworkers::SystemSchedules::JOURNALING)
    starts_at = 1.day.from_now.beginning_of_day

    metadata = events(starts_at:, ends_at: starts_at + 1.day).sole.fetch(:metadata)

    expect(metadata).to include(system_schedule: true,
      system_key: Coworkers::SystemSchedules::JOURNALING, after_run: "quiet")
  end

  it "correlates actual execution and distinguishes delayed, successful, and failed work" do
    scheduled = task(created_at: 2.days.ago)
    starts_at = 1.day.ago.beginning_of_day
    planned_at = events(starts_at:, ends_at: starts_at + 1.day).sole.fetch(:starts_at)
    job = Job.create!(user: owner, repository:, kind: "coworker_task", priority: "low",
      scheduled_task_id: scheduled.id, origin: "coworkers", origin_id: coworker.id.to_s,
      issue_title: "Scheduled coworker task", issue_body: "Brief me", issue_number: nil,
      created_at: planned_at + 1.minute)
    workflow = Workflow.create!(job:, user: owner, trigger_kind: "coworker_run", state: "queued")
    attach_work_unit(workflow, state: "blocked", blocked_reason: "coworker_turn_in_flight")

    delayed = events(starts_at:, ends_at: starts_at + 1.day).sole
    expect(delayed).to include(state: "delayed", actual_started_at: nil)
    expect(delayed.fetch(:metadata)).to include(delayed_reason: "coworker_turn_in_flight")

    workflow.update!(state: "succeeded", started_at: planned_at + 4.minutes, finished_at: planned_at + 9.minutes)
    completed = events(starts_at:, ends_at: starts_at + 1.day).sole
    expect(completed).to include(state: "success", actual_started_at: planned_at + 4.minutes,
      actual_finished_at: planned_at + 9.minutes)
    expect(completed.fetch(:metadata)).to include(duration_seconds: 300.0, workflow_state: "succeeded")

    workflow.update!(state: "failed")
    expect(events(starts_at:, ends_at: starts_at + 1.day).sole).to include(state: "failure")
  end

  it "marks a created occurrence without execution evidence as waiting" do
    scheduled = task(created_at: 2.days.ago)
    starts_at = 1.day.ago.beginning_of_day
    planned_at = events(starts_at:, ends_at: starts_at + 1.day).sole.fetch(:starts_at)
    Job.create!(user: owner, repository:, kind: "coworker_task", priority: "low",
      scheduled_task_id: scheduled.id, origin: "coworkers", origin_id: coworker.id.to_s,
      issue_title: "Scheduled coworker task", issue_body: "Brief me", issue_number: nil,
      created_at: planned_at + 1.minute)

    expect(events(starts_at:, ends_at: starts_at + 1.day).sole).to include(state: "waiting")
  end
end
