module ReviewWorkspacePlugin
  # The implementation commit the Job's review evidence must cover: the head
  # recorded by the newest succeeded implement/respond step. Mirrors how review
  # gates stamp `reviewed_head_sha`, so the brief can tell current review
  # evidence from evidence superseded by a later repair. Nil when unknown.
  class CurrentHead
    MUTATION_KINDS = %w[implement respond].freeze

    def self.call(job)
      job.workflows.reorder(id: :desc).each do |workflow|
        sha = workflow.steps.where(kind: MUTATION_KINDS, state: "succeeded").reorder(position: :desc, id: :desc)
          .includes(:runs).filter_map { |step| step.runs.last&.head_sha.presence }.first
        return sha if sha
      end
      nil
    end
  end
end
