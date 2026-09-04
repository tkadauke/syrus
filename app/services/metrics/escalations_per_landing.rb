module Metrics
  # The plan's one metric (workflow-engine-v3): escalations per landing,
  # trending down. Flat means the ladder is not learning.
  #
  # Escalations are Decisions opened in the window -- one per distinct problem,
  # not per occurrence, because Decisions::Opener collapses repeats. Landings
  # are the workflows that actually put code on the base branch. The ratio is
  # "how much human attention did it cost to land something", which is the
  # question the whole attention model exists to answer.
  #
  # A period with landings and no escalations scores 0.0. A period with
  # escalations and no landings has no ratio at all rather than a misleading
  # infinity, so `ratio` is nil and callers say so.
  class EscalationsPerLanding
    LANDING_TRIGGER_KINDS = %w[auto_merge merge_train].freeze

    Result = Data.define(:escalations, :landings, :ratio, :from, :to, :by_problem_code) do
      def landings? = landings.positive?
      def to_s = landings? ? format("%.2f escalations per landing", ratio) : "no landings in window"
    end

    def self.call(...) = new(...).call

    def initialize(from: 7.days.ago, to: Time.current, repository: nil, queue: "operator")
      @from = from
      @to = to
      @repository = repository
      @queue = queue
    end

    def call
      escalations = decisions.count
      landings = landed_workflows.count

      Result.new(
        escalations: escalations,
        landings: landings,
        ratio: landings.positive? ? (escalations.to_f / landings) : nil,
        from: @from,
        to: @to,
        by_problem_code: decisions.group(:problem_code).count
      )
    end

    private

    def decisions
      scope = Decision.for_queue(@queue).where(created_at: @from..@to)
      @repository ? scope.where(repository: @repository) : scope
    end

    def landed_workflows
      scope = Workflow.where(trigger_kind: LANDING_TRIGGER_KINDS, state: "succeeded", finished_at: @from..@to)
      return scope unless @repository

      scope.joins(:job).where(jobs: { repository_id: @repository.id })
    end
  end
end
