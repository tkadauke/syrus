module LargeJobInspectionFixture
  def build_large_inspection_job(user:, repository:, run_count: 205)
    job = Factories.job(repository: repository)
    workflow = job.latest_workflow
    workflow.update_column(:trigger_kind, "merge_train")
    workflow.runs.update_all(trigger_kind: "merge_train")
    now = Time.current
    Step.insert_all!(run_count.times.map do |index|
      {
        workflow_id: workflow.id, kind: "implement", position: index + 1, iteration: 1,
        state: "succeeded", details: {}, depends_on_ids: [],
        placement_policy: "pinned_workflow_workspace", created_at: now, updated_at: now
      }
    end)
    step_ids = Step.where(workflow_id: workflow.id).where.not(id: workflow.first_step.id).pluck(:id)
    Run.insert_all!(step_ids.map.with_index do |step_id, index|
      {
        job_id: job.id, user_id: user.id, step_id: step_id, trigger_kind: workflow.trigger_kind,
        state: "succeeded", agent_provider: "claude", iteration: 1, effective_at: now,
        prompt: "wide prompt #{index}" * 1_000, created_at: now + index.seconds, updated_at: now
      }
    end)
    job
  end

  def capture_inspection_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA"

      queries << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end
end

RSpec.configure do |config|
  config.include LargeJobInspectionFixture
end
