class RecurringTaskTickJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  def perform
    return if AppSetting.polling_paused?

    now = Time.current
    RecurringTask
      .due(now)
      .joins(:repository).merge(Repository.active)
      .joins(:user).where(users: { scheduling_paused: false })
      .find_each do |task|
        fire_task(task, now: now)
      rescue StandardError => e
        Rails.logger.warn("[RecurringTaskTickJob] task ##{task.id} failed: #{e.class}: #{e.message}")
      end
  end

  private

  def fire_task(task, now:)
    task.with_lock do
      task.reload
      return unless task.enabled? && task.next_fire_at <= now

      job = create_job(task)
      start_workflow(job, prompt: task.prompt)
      task.advance!(from: now)

      Rails.logger.info("[RecurringTaskTickJob] task ##{task.id} fired -> job ##{job.id}")
    end
  end

  def create_job(task)
    task.user.jobs.create!(
      repository: task.repository,
      kind: "adhoc",
      issue_number: nil,
      issue_title: "Recurring task: #{task.label}",
      issue_body: task.prompt,
      agent_provider: task.repository.effective_agent_provider
    )
  end

  def start_workflow(job, prompt:)
    rendered_prompt = Prompts::AdhocJob.new(prompt: prompt).to_s
    workflow = Workflows::Initial.instantiate(job: job, agent_provider: job.agent_provider)
    StepDispatcher.start_workflow(workflow, prompt: rendered_prompt)
  end
end
