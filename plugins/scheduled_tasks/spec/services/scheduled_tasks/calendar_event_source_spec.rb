require "rails_helper"

RSpec.describe ScheduledTasks::CalendarEventSource do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }

  def task(**attributes)
    ScheduledTasks::Task.create!({
      user:, repository:, name: "Repository sweep", prompt: "Inspect it.", kind: "cron",
      cron_expression: "0 9 * * *", schedule_timezone: "America/New_York",
      pr_pileup_policy: "skip", minute_offset: 0
    }.merge(attributes))
  end

  def events(starts_at:, ends_at:)
    described_class.calendar_events(user:, starts_at:, ends_at:)
  end

  it "expands only occurrences inside the requested range in the stored timezone" do
    task(created_at: Time.utc(2026, 3, 6))
    starts_at = Time.utc(2026, 3, 7, 0)

    result = events(starts_at:, ends_at: Time.utc(2026, 3, 10, 0))

    expect(result.map(&:starts_at)).to eq([
      Time.utc(2026, 3, 7, 14), Time.utc(2026, 3, 8, 13), Time.utc(2026, 3, 9, 13)
    ])
    expect(result.map(&:id).uniq.size).to eq(3)
    expect(result).to all(have_attributes(state: "skipped", destination_path: a_string_matching(%r{\A/scheduled_tasks/})))
  end

  it "includes one-shot boundaries once and excludes Coworker-owned and inaccessible tasks" do
    instant = 2.days.from_now.change(usec: 0)
    task(kind: "one_shot", cron_expression: nil, fire_at: instant, name: "One shot")
    task(coworker_id: 123, name: "Coworker task")
    other_user = Factories.user
    other_repository = Factories.repository(user: other_user)
    task(user: other_user, repository: other_repository, name: "Private task")

    result = events(starts_at: instant, ends_at: instant + 1.hour)

    expect(result.map(&:title)).to eq([ "One shot" ])
    expect(events(starts_at: instant - 1.hour, ends_at: instant).map(&:title)).to be_empty
  end

  it "correlates a visible Job and Workflow and links both execution and schedule details" do
    range_start = 1.day.ago.beginning_of_day
    scheduled = task(created_at: range_start - 1.day)
    planned_at = events(starts_at: range_start, ends_at: range_start + 1.day).first.starts_at
    job = Factories.job(repository:, user:, kind: "cron", issue_number: nil,
      scheduled_task_id: scheduled.id, origin: "scheduled_tasks", origin_id: scheduled.id.to_s,
      issue_title: "Scheduled task: Repository sweep", created_at: planned_at + 2.minutes)
    workflow = Workflow.create!(job:, user:, trigger_kind: "initial", state: "failed",
      started_at: planned_at + 3.minutes, finished_at: planned_at + 8.minutes)

    event = events(starts_at: range_start, ends_at: range_start + 1.day).first

    expect(event).to have_attributes(state: "failure", destination_path: "/jobs/#{job.id}",
      actual_started_at: planned_at + 3.minutes, actual_finished_at: planned_at + 8.minutes)
    expect(event.metadata).to include(job_id: job.id, job_path: "/jobs/#{job.id}",
      scheduled_task_path: "/scheduled_tasks/#{scheduled.id}", workflow_id: workflow.id)
  end

  it "surfaces future pause states and historical fired and skipped states" do
    future_start = 1.day.from_now.beginning_of_day
    task(name: "Paused", state: "paused", created_at: 1.day.ago)
    task(name: "Auto-paused", state: "auto_paused", created_at: 1.day.ago)

    future = events(starts_at: future_start, ends_at: future_start + 3.days).index_by(&:title)
    expect(future.values_at("Paused", "Auto-paused").map(&:state)).to eq(%w[paused auto_paused])

    past_start = 2.days.ago.beginning_of_day
    task(name: "Skipped", created_at: past_start - 1.day)
    fired = task(kind: "one_shot", cron_expression: nil, fire_at: 1.day.from_now, name: "Fired")
    fired.update_columns(created_at: past_start - 1.day, fire_at: past_start + 1.hour, state: "fired")
    past = events(starts_at: past_start, ends_at: past_start + 1.day).index_by(&:title)
    expect(past.fetch("Skipped").state).to eq("skipped")
    expect(past.fetch("Fired").state).to eq("fired")
  end

  it "limits recurring occurrences to the task lifetime without rewriting historical state" do
    starts_at = Time.utc(2026, 3, 7)
    scheduled = task(name: "Lifetime", state: "paused", created_at: Time.utc(2026, 3, 8, 12))
    scheduled.update_columns(archived_at: Time.utc(2026, 3, 10, 12))

    result = events(starts_at:, ends_at: Time.utc(2026, 3, 12))

    expect(result.map(&:starts_at)).to eq([ Time.utc(2026, 3, 8, 13), Time.utc(2026, 3, 9, 13) ])
    expect(result).to all(have_attributes(state: "skipped"))
  end

  it "claims each Job for at most one occurrence" do
    starts_at = 2.days.ago.beginning_of_day
    scheduled = task(created_at: starts_at - 1.day)
    planned_times = [ starts_at, starts_at + 30.minutes ]
    job = Factories.job(repository:, user:, kind: "cron", issue_number: nil,
      scheduled_task_id: scheduled.id, created_at: starts_at + 45.minutes)
    source = described_class.new(user:, starts_at:, ends_at: starts_at + 2.hours)
    allow(source).to receive(:occurrences).with(have_attributes(id: scheduled.id)).and_return(planned_times)

    result = source.calendar_events

    expect(result.count { |event| event.metadata[:job_id] == job.id }).to eq(1)
  end
end
