module Coworkers
  class PostToChat < ::Steps::Base
    def self.post_failure!(workflow)
      job = workflow.job
      coworker = Coworkers::Coworker.find(job.origin_id)
      chat = coworker.coworker_chats.find_by!(role: "main").chat_session
      failed_run = workflow.steps.find_by!(kind: "coworker_run").runs.where(state: "failed").order(:created_at).last
      merge = finalize_workspace!(chat:, workflow:, source_run: failed_run)
      duration = if failed_run&.started_at && failed_run.finished_at
        (failed_run.finished_at - failed_run.started_at).round(1)
      end
      chat.messages.create!(
        role: "assistant",
        content: {
          "text" => "Background task failed.",
          "background_run" => {
            "job_id" => job.id, "workflow_id" => workflow.id,
            "run_id" => failed_run&.id, "state" => "failed",
            "summary" => failed_run&.agent_summary.presence || "Background task failed.",
            "duration_seconds" => duration,
            "cost_usd" => failed_run&.cost_usd&.to_s,
            "merge_state" => merge.to_s
          }
        },
        skip_turn_trigger: true
      )
    end

    def call
      coworker = Coworkers::Coworker.find(job.origin_id)
      chat = coworker.coworker_chats.find_by!(role: "main").chat_session
      source_run = workflow.steps.find_by!(kind: "coworker_run").runs.where(state: "succeeded").order(:created_at).last!
      summary = source_run.agent_summary.presence || "Background task completed."
      merge = self.class.finalize_workspace!(chat:, workflow:, source_run: source_run, path: workspace.path)
      duration = if source_run.started_at && source_run.finished_at
        (source_run.finished_at - source_run.started_at).round(1)
      end

      chat.messages.create!(
        role: "assistant",
        content: {
          "text" => summary,
          "body_format" => "markdown",
          "background_run" => {
            "job_id" => job.id,
            "workflow_id" => workflow.id,
            "run_id" => source_run.id,
            "state" => source_run.state,
            "summary" => summary,
            "duration_seconds" => duration,
            "cost_usd" => source_run.cost_usd&.to_s,
            "merge_state" => merge.to_s
          }
        },
        skip_turn_trigger: true
      )
    end

    def self.finalize_workspace!(chat:, workflow:, source_run:, path: nil)
      return :unavailable unless source_run

      path ||= StepWorkspace.for(source_run.step, run: source_run).path
      Coworkers::ChatWorkspaceLifecycle.new(chat).finalize_background!(path:, workflow:)
    end
  end
end
