module Workflows
  # Triggered by complete_implement_step after the Local Mode daemon has
  # committed and pushed the implementation. Skips the agent implement step
  # (code is already on the branch) and goes straight to graders, then
  # wraps up based on whether the Job already has a PR or not.
  #
  # On grader failure: reverts the Job to :coding so the operator can fix
  # and re-run complete_implement_step (mirrors coding_handoff behavior).
  # On non-grader failure: drives the Job to :failed so the operator has
  # the normal Retry path.
  class LocalModeHandoff < Base
    def self.trigger_kind = "local_mode_handoff"

    def self.steps_for(job)
      chain = if job.pr_number.present?
        # PR already exists (taken-over implemented Job) — update it
        [
          "prepare",
          "grader_fanout",
          "grader_collect",
          "summarize_amend",
          follow_up_push(max_iterations: AppSetting.grade_max_iterations)
        ]
      else
        # No PR yet (new coding Job) — open one after graders pass
        [
          "prepare",
          "grader_fanout",
          "grader_collect",
          "summarize",
          "test_plan",
          "pr_open"
        ]
      end
      prepare_skipped_for?(job) ? chain.reject { |node| node == "prepare" } : chain
    end

    def self.prepare_skipped_for?(job)
      job.skip_prepare?
    end

    def self.after_success(workflow)
      workflow.job.update!(linked_chat_id: nil) if workflow.job.linked_chat_id.present?
    end

    def self.after_fail(workflow)
      chat = ChatSession.find_by(id: workflow.job.linked_chat_id)

      if grader_failure?(workflow)
        GraderChatReporter.report_failure(workflow: workflow, chat: chat) if chat
        if workflow.job.may_revert_to_coding_mode?
          workflow.job.revert_to_coding_mode!
          workflow.job.save!
        end
      else
        # Non-grader failure (e.g. prepare failed). propagate_fail_to_job!
        # was suppressed, so drive the job to :failed manually so the
        # operator has the normal Retry path.
        if workflow.job.may_mark_failed?
          workflow.job.mark_failed!
          workflow.job.save!
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[LocalModeHandoff] after_fail raised for workflow #{workflow.id}: #{e.class}: #{e.message}")
    end

    def self.grader_failure?(workflow)
      workflow.steps.where(kind: "grader_collect", state: "failed").exists?
    end
  end
end
