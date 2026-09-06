module Workflows
  # Post-coding-mode handoff: reviews and grades the code the chat agent
  # wrote, repairs review/grader findings with fresh workflow-agent turns,
  # then opens the PR. Instantiated by the complete_implement_step MCP tool
  # once the agent commits and pushes from the chat workspace.
  #
  # There is no bare leading agentic step here — the chat coding session
  # already produced the diff before this workflow starts. `coding_handoff_fix`
  # plays the "agent_step" role the adversarial/visual review loops and the
  # grader retry loop all repair through, the same way `implement` does for
  # Initial/Retry. Review-loop iteration 1 reviews that pre-existing diff
  # directly (see Steps::AdversarialReview/VisualReview#latest_agentic_diff,
  # which fall back to a fresh `git diff` when no implement/respond step
  # exists in the chain).
  #
  # On grader pass: workflow succeeds, PR is opened by pr_open, and
  # after_success posts a confirmation to the originating chat, enqueues
  # reclaim, then clears linked_chat_id when available.
  # On terminal grader failure after the retry budget is exhausted, after_fail
  # posts a passive report to that chat and marks the Job failed.
  class CodingHandoff < Base
    def self.trigger_kind = "coding_handoff"

    def self.steps_for(job)
      syrus_yml = resolve_default_branch_syrus_yml(job)
      prepare_then(
        job,
        adversarial_review_loop(job, agent_step: :coding_handoff_fix),
        visual_review_loop(job, agent_step: :coding_handoff_fix),
        Workflows::RetryUntil.new(
          max_iterations: AppSetting.grade_max_iterations,
          repair_first: false,
          repair: [ :coding_handoff_fix ],
          check: [ :grader_fanout, :grader_collect ]
        ),
        initial_pr_finish_steps(job, syrus_yml: syrus_yml)
      )
    end

    def self.after_success(workflow)
      return unless Feature.coding_mode_enabled?

      chat_id = chat_id_for(workflow)
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

      chat = ChatSession.find_by(id: chat_id_for(workflow))

      if grader_failure?(workflow)
        GraderChatReporter.report_failure(workflow: workflow, chat: chat, enqueue_agent_turn: false) if chat
        if workflow.job.may_mark_failed?
          workflow.job.mark_failed!
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

    def self.chat_id_for(workflow)
      workflow.artifact("coding_handoff_chat_id").presence ||
        workflow.artifact("coding_handoff").to_h["chat_session_id"].presence ||
        workflow.job.linked_chat_id
    end
  end
end
