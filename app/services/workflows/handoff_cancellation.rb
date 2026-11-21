module Workflows
  # Coding-mode and local-mode handoffs own their Job's lifecycle: generic
  # propagation skips both their failure and their cancellation. Each handoff
  # lifts its Job to :running when it starts, so a cancelled handoff must settle
  # that Job itself, the same way generic cancel propagation would: fail a Job
  # it left :running, unless newer work superseded it.
  module HandoffCancellation
    module_function

    def settle_job!(workflow, clear_chat_link: false)
      return if workflow.superseded_cancellation?

      job = workflow.job
      StateTransition.with_source("propagate") do
        job.linked_chat_id = nil if clear_chat_link && job.linked_chat_id.present?
        job.mark_failed! if job.running? && job.may_mark_failed?
        job.save! if job.changed?
      end
    end
  end
end
