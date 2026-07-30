module Workflows
  # Post-coding-mode handoff: runs graders on the code the chat agent wrote,
  # then opens (or updates) the PR. Instantiated by the complete_implement_step
  # MCP tool once the agent commits and pushes from the chat workspace.
  #
  # On grader pass: workflow succeeds, PR is opened by pr_open, after_success
  # posts a confirmation to the linked chat, enqueues reclaim, then clears
  # linked_chat_id.
  #
  # On grader fail: grader_collect raises StepFailed with no loop node to
  # catch it, so hard_fail_workflow! fires. after_fail posts the failure report
  # to the linked chat and reverts the job to :coding so the operator can fix
  # and re-run complete_implement_step.
  class CodingHandoff < Base
    def self.trigger_kind = "coding_handoff"

    def self.steps_for(job)
      chain = [ "prepare", "grader_fanout", "grader_collect", "summarize", "test_plan", "pr_open" ]
      prepare_skipped_for?(job) ? chain.reject { |s| s == "prepare" } : chain
    end

    def self.after_success(workflow)
      return unless Feature.coding_mode_enabled?

      chat_id = workflow.job.linked_chat_id
      return unless chat_id

      chat = ChatSession.find_by(id: chat_id)
      unless chat
        workflow.job.update!(linked_chat_id: nil)
        return
      end

      GraderChatReporter.report_success(workflow: workflow, chat: chat)

      # The branch is pushed and the PR is open, so the chat's coding checkout
      # is now fully reproducible from the remote — reclaim its disk. This
      # after_success runs on a compute pod, so hop to the `chat` queue where
      # the workspace actually lives (ChatCodingWorkspaceReclaimJob).
      ChatCodingWorkspaceReclaimJob.perform_later(chat.id)

      workflow.job.update!(linked_chat_id: nil)
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
