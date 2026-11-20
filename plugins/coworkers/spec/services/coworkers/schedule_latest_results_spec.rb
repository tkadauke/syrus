require "rails_helper"

RSpec.describe Coworkers::ScheduleLatestResults do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-latest", workspace_repo: repository.remote_url)
  end

  def task(name:, system_key: nil)
    ScheduledTasks::Task.create!(
      user: owner, repository: repository, coworker_id: coworker.id, name: name,
      prompt: "Do it", kind: "cron", cron_expression: "0 9 * * *", system_key: system_key
    )
  end

  def scheduled_job(task, workflow_state: "succeeded", target_date: nil, failure_reason: nil)
    job = Factories.job_record(user: owner, repository: repository, kind: "coworker_task",
      scheduled_task_id: task.id, issue_number: nil)
    workflow = Workflow.create!(job: job, user: owner, trigger_kind: "coworker_run", state: workflow_state,
      failure_reason: failure_reason)
    workflow.set_artifact!("journaling_target_on", target_date) if target_date
    job
  end

  it "summarizes the latest ordinary Job and its failure" do
    schedule = task(name: "Daily review")
    older = scheduled_job(schedule)
    latest = scheduled_job(schedule, workflow_state: "failed", failure_reason: "Workspace locked")

    result = described_class.new(tasks: [ schedule ], user: owner).call.fetch(schedule)

    expect(result).to include(outcome: "failed", reason: "Workspace locked", job: include(id: latest.id))
    expect(result.dig(:job, :id)).not_to eq(older.id)
  end

  it "links Journaling only through the exact structured target date" do
    schedule = task(name: "Journaling", system_key: Coworkers::SystemSchedules::JOURNALING)
    scheduled_job(schedule, target_date: "2026-11-02")
    schedule.record_system_result!(date: Date.new(2026, 11, 3), result: "skipped", reason: "dormant")

    result = described_class.new(tasks: [ schedule ], user: owner).call.fetch(schedule)

    expect(result).to include(target_date: "2026-11-03", outcome: "skipped", reason: "dormant", job: nil, job_needed: false)
  end

  it "links the exact Journaling Job when a newer Job belongs to another target" do
    schedule = task(name: "Journaling", system_key: Coworkers::SystemSchedules::JOURNALING)
    matching = scheduled_job(schedule, target_date: "2026-11-03")
    newer = scheduled_job(schedule, target_date: "2026-11-04")
    schedule.record_system_result!(date: Date.new(2026, 11, 3), result: "journaled")

    result = described_class.new(tasks: [ schedule ], user: owner).call.fetch(schedule)

    expect(result).to include(target_date: "2026-11-03", outcome: "journaled", job_needed: true, job: include(id: matching.id))
    expect(result.dig(:job, :id)).not_to eq(newer.id)
  end

  it "distinguishes a never-run schedule from a no-Job system occurrence" do
    schedule = task(name: "Unused")
    expect(described_class.new(tasks: [ schedule ], user: owner).call.fetch(schedule)).to include(outcome: "never_run", job_needed: nil)
  end

  it "loads summaries in a fixed query count" do
    tasks = [ task(name: "First"), task(name: "Second") ]
    tasks.each { |schedule| scheduled_job(schedule) }
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) && payload[:name] != "SCHEMA"
    end

    described_class.new(tasks: tasks, user: owner).call

    expect(queries.size).to be <= 5
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
