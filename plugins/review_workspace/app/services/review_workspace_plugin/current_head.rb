module ReviewWorkspacePlugin
  # The implementation commit the Job's review evidence must cover: the head
  # recorded by the newest succeeded implement/respond step across the Job's
  # workflows (newest workflow, then latest step). Mirrors how review gates
  # stamp `reviewed_head_sha`. Nil when unknown.
  #
  # Uses a fixed number of queries (one joined step query plus one run
  # preload) regardless of how many workflows the Job has accumulated.
  class CurrentHead
    MUTATION_KINDS = %w[implement respond].freeze
    CANDIDATE_LIMIT = 50

    def self.call(job)
      Step.joins(:workflow)
        .where(workflows: { job_id: job.id }, kind: MUTATION_KINDS, state: "succeeded")
        .reorder("workflows.id DESC, steps.position DESC, steps.id DESC")
        .limit(CANDIDATE_LIMIT)
        .includes(:runs)
        .filter_map { |step| step.runs.max_by(&:id)&.head_sha.presence }
        .first
    end
  end
end
