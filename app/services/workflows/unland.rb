module Workflows
  # Builds a compensating revert from the current default branch, lets the
  # implementing agent resolve conflicts, and publishes a normal review PR.
  class Unland < Base
    steps :unland_revert, :unland_conflict, :prepare, :grader_fanout,
          :grader_collect, :summarize, :pr_open

    def self.trigger_kind = "unland"

    def self.queue_name = :merges

    def self.after_fail(workflow)
      workflow.job.mark_failed! if workflow.job.may_mark_failed?
    end

    def self.after_cancel(workflow)
      workflow.job.mark_failed! if workflow.job.may_mark_failed?
    end
  end
end
