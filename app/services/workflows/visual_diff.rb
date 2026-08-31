module Workflows
  # Deferred before/after screenshot comparison for an already implemented Job.
  # The workflow runs at low priority and owns no Job lifecycle transitions.
  class VisualDiff < Base
    def self.trigger_kind = "visual_diff"
    def self.agentic? = true

    def self.solid_queue_priority(_workflow) = Job::PRIORITY_TO_SQ.fetch("low")

    def self.steps_for(job)
      prepare_then(job, "visual_diff")
    end
  end
end
