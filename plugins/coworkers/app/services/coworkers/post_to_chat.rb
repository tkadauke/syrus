module Coworkers
  class PostToChat < ::Steps::Base
    MESSAGE_ARTIFACT = "coworker_chat_message_id"
    MERGE_ARTIFACT = "coworker_merge_state"

    def self.post_failure!(workflow)
      return if workflow.reload.artifact(MESSAGE_ARTIFACT).present?

      job = workflow.job
      coworker = Coworkers::Coworker.find(job.origin_id)
      chat = coworker.coworker_chats.find_by!(role: "main").chat_session
      failed_run = workflow.steps.find_by!(kind: "coworker_run").runs.where(state: "failed").order(:created_at).last
      merge = finalize_once!(chat:, workflow:, source_run: failed_run)
      duration = (failed_run.finished_at - failed_run.started_at).round(1) if failed_run&.started_at && failed_run.finished_at
      summary = summary_for(failed_run, fallback: "Background task failed.")

      post_once!(workflow:, chat:, merge:, content: {
        "text" => summary,
        "body_format" => "markdown",
        "background_run" => {
          "job_id" => job.id, "workflow_id" => workflow.id,
          "run_id" => failed_run&.id, "state" => "failed",
          "summary" => summary, "duration_seconds" => duration,
          "cost_usd" => failed_run&.cost_usd&.to_s, "merge_state" => merge.to_s
        }
      })
    end

    def call
      return if workflow.reload.artifact(MESSAGE_ARTIFACT).present?

      coworker = Coworkers::Coworker.find(job.origin_id)
      chat = coworker.coworker_chats.find_by!(role: "main").chat_session
      source_run = workflow.steps.find_by!(kind: "coworker_run").runs.where(state: "succeeded").order(:created_at).last!
      summary = self.class.summary_for(source_run, fallback: "Background task completed.")
      merge = self.class.finalize_once!(chat:, workflow:, source_run:, path: workspace.path)
      duration = (source_run.finished_at - source_run.started_at).round(1) if source_run.started_at && source_run.finished_at

      self.class.post_once!(workflow:, chat:, merge:, content: {
        "text" => summary,
        "body_format" => "markdown",
        "background_run" => {
          "job_id" => job.id, "workflow_id" => workflow.id,
          "run_id" => source_run.id, "state" => source_run.state,
          "summary" => summary, "duration_seconds" => duration,
          "cost_usd" => source_run.cost_usd&.to_s, "merge_state" => merge.to_s
        }
      })
    end

    def self.post_once!(workflow:, chat:, merge:, content:)
      workflow.class.transaction do
        locked = workflow.class.lock.find(workflow.id)
        return chat.messages.find_by(id: locked.artifact(MESSAGE_ARTIFACT)) if locked.artifact(MESSAGE_ARTIFACT).present?

        message = chat.messages.create!(role: "assistant", content:, skip_turn_trigger: true)
        locked[:artifacts] = locked[:artifacts].to_h.merge(
          MESSAGE_ARTIFACT => message.id,
          MERGE_ARTIFACT => merge.to_s
        )
        locked.save!
        message
      end
    end

    def self.finalize_once!(chat:, workflow:, source_run:, path: nil)
      recorded = workflow.reload.artifact(MERGE_ARTIFACT).presence
      return recorded.to_sym if recorded

      merge = finalize_workspace!(chat:, workflow:, source_run:, path:)
      workflow.set_artifact!(MERGE_ARTIFACT, merge.to_s)
      merge
    end

    def self.finalize_workspace!(chat:, workflow:, source_run:, path: nil)
      return :unavailable unless source_run

      path ||= StepWorkspace.for(source_run.step, run: source_run).path
      Coworkers::ChatWorkspaceLifecycle.new(chat).finalize_background!(path:, workflow:)
    end

    def self.summary_for(source_run, fallback:)
      return fallback unless source_run
      return source_run.agent_summary if source_run.agent_summary.present?

      message = Array(source_run.provider_session&.normalized_messages).reverse.find do |candidate|
        candidate["role"] == "assistant" && candidate["sidechain"] != true && candidate["content"].to_s.present?
      end
      message&.fetch("content", nil).to_s.strip.presence || fallback
    end
  end
end
