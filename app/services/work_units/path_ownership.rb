module WorkUnits
  class PathOwnership
    Result = Data.define(:path, :owner, :gate) do
      def legacy? = owner == :legacy
      def work_unit? = owner == :work_unit
      def gated? = gate.present?
    end

    SCHEDULER_PATHS = %w[
      retry
      auto_retry_backoff
      resume
      manual_pause
      admission_control_pause
      provider_availability_pause
    ].freeze

    LANDING_PATHS = %w[
      auto_merge
      external_pr_merge
      landing_queue
      landing_validation
      merge_train
      merge_train_validation
      stack_rebase
    ].freeze

    RECONCILER_PATHS = %w[
      epic_wide_workflow
      orphaned_queued_runs
      paused_units
      stale_runs
      terminal_orphan_workflows
      workflow_repair
    ].freeze

    PATH_GATES = SCHEDULER_PATHS.index_with("work_units_scheduler")
      .merge(LANDING_PATHS.index_with("work_units_landing"))
      .merge(RECONCILER_PATHS.index_with("work_units_reconciler"))
      .freeze

    def self.for(path)
      new(path).result
    end

    def self.work_unit_owned?(path)
      self.for(path).work_unit?
    end

    def initialize(path)
      @path = path.to_s
    end

    def result
      gate = PATH_GATES.fetch(path) { raise KeyError, "unknown work unit ownership path: #{path.inspect}" }
      owner = Feature.enabled?(gate) ? :work_unit : :legacy
      Result.new(path: path, owner: owner, gate: gate)
    end

    private

    attr_reader :path
  end
end
