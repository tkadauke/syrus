module Workflows
  # Triggered by complete_implement_step after the Local Mode daemon has
  # committed and pushed the implementation. Skips the agent implement step
  # (code is already on the branch), validates it with graders, repairs grader
  # failures with workflow-agent turns, then wraps up based on whether the Job
  # already has a PR or not.
  #
  # On terminal grader failure after the retry budget is exhausted, after_fail
  # posts a passive report to the originating chat and marks the Job failed.
  # On non-grader failure: drives the Job to :failed so the operator has
  # the normal Retry path.
  class LocalModeHandoff < Base
    def self.trigger_kind = "local_mode_handoff"

    def self.steps_for(job)
      grader_loop = Workflows::RetryUntil.new(
        max_iterations: AppSetting.grade_max_iterations,
        repair_first: false,
        repair: [ :local_mode_handoff_fix ],
        check: [ :grader_fanout, :grader_collect ]
      )

      finish_steps = if job.pr_number.present?
        # PR already exists (taken-over implemented Job) — update it
        [
          grader_loop,
          "summarize_amend",
          follow_up_push(max_iterations: AppSetting.grade_max_iterations)
        ]
      else
        # No PR yet (new coding Job) — open one after graders pass
        [ grader_loop, initial_pr_finish_steps ]
      end

      prepare_then(job, finish_steps)
    end

    def self.after_success(workflow)
      workflow.job.update!(linked_chat_id: nil) if workflow.job.linked_chat_id.present?
    end

    def self.after_fail(workflow)
      chat = ChatSession.find_by(id: workflow.job.linked_chat_id)

      if grader_failure?(workflow)
        GraderChatReporter.report_failure(workflow: workflow, chat: chat, enqueue_agent_turn: false) if chat
        mark_failed_and_clear_chat_link!(workflow.job)
      else
        # Non-grader failure (e.g. prepare failed). propagate_fail_to_job!
        # was suppressed, so drive the job to :failed manually so the
        # operator has the normal Retry path.
        mark_failed_and_clear_chat_link!(workflow.job)
      end
    rescue StandardError => e
      Rails.logger.warn("[LocalModeHandoff] after_fail raised for workflow #{workflow.id}: #{e.class}: #{e.message}")
    end

    def self.grader_failure?(workflow)
      workflow.steps.where(kind: "grader_collect", state: "failed").exists?
    end

    def self.mark_failed_and_clear_chat_link!(job)
      job.linked_chat_id = nil if job.linked_chat_id.present?
      job.mark_failed! if job.may_mark_failed?
      job.save! if job.changed?
    end
  end
end
