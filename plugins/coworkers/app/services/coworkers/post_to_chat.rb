module Coworkers
  class PostToChat < ::Steps::Base
    def self.post_failure!(workflow)
      job = workflow.job
      coworker = Coworkers::Coworker.find(job.origin_id)
      chat = coworker.coworker_chats.find_by!(role: "main").chat_session
      failed_run = workflow.steps.find_by!(kind: "coworker_run").runs.where(state: "failed").order(:created_at).last
      chat.messages.create!(
        role: "assistant",
        content: {
          "text" => "Background task failed.",
          "background_run" => {
            "job_id" => job.id, "workflow_id" => workflow.id,
            "run_id" => failed_run&.id, "state" => "failed"
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

      chat.messages.create!(
        role: "assistant",
        content: {
          "text" => summary,
          "body_format" => "markdown",
          "background_run" => {
            "job_id" => job.id,
            "workflow_id" => workflow.id,
            "run_id" => source_run.id,
            "state" => source_run.state
          }
        },
        skip_turn_trigger: true
      )
    end
  end
end
