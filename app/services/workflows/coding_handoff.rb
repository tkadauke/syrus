module Workflows
  # Runs after the operator signals completion from a Coding Mode chat session.
  # Validates the code with graders; if they pass, opens the PR. Results are
  # posted back to the linked chat session so the operator can iterate.
  #
  # On grader pass: workflow succeeds, PR is opened by pr_open, after_success
  # posts a confirmation to the linked chat and clears linked_chat_id.
  #
  # On grader fail: grader_collect raises StepFailed with no loop node to
  # catch it, so hard_fail_workflow! fires. propagate_fail_to_job! is
  # suppressed for coding_handoff; after_fail posts the failure report to
  # the linked chat and reverts the job to :coding so the operator can fix
  # and re-run complete_implement_step.
  #
  # On non-grader failure (e.g. prepare): after_fail propagates to job
  # :failed the normal way; no chat message (the job falls into the normal
  # operator-driven retry flow).
  class CodingHandoff < Base
    def self.trigger_kind = "coding_handoff"

    def self.steps_for(job)
      chain = %w[ grader_fanout grader_collect summarize test_plan pr_open ]
      prepare_skipped_for?(job) ? chain : %w[ prepare ] + chain
    end

    def self.prepare_skipped_for?(job)
      job.skip_prepare?
    end

    def self.after_success(workflow)
      return unless Feature.coding_mode_enabled?

      chat_id = workflow.job.linked_chat_id
      return unless chat_id

      workflow.job.update!(linked_chat_id: nil)

      chat = ChatSession.find_by(id: chat_id)
      return unless chat

      GraderChatReporter.report_success(workflow: workflow, chat: chat)
    end

    def self.after_fail(workflow)
      return unless Feature.coding_mode_enabled?

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
      Rails.logger.warn("[CodingHandoff] after_fail raised for workflow #{workflow.id}: #{e.class}: #{e.message}")
    end

    def self.grader_failure?(workflow)
      workflow.steps.where(kind: "grader_collect", state: "failed").exists?
    end
  end
end
