module WorkUnits
  class PathOwnership
    Result = Data.define(:path, :owner, :group) do
      def legacy? = owner == :legacy
      def work_unit? = owner == :work_unit
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
      job_bundle
      job_bundle_validation
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

    PATH_GROUPS = SCHEDULER_PATHS.index_with("scheduler")
      .merge(LANDING_PATHS.index_with("landing"))
      .merge(RECONCILER_PATHS.index_with("reconciler"))
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
      group = PATH_GROUPS.fetch(path) { raise KeyError, "unknown work unit ownership path: #{path.inspect}" }
      Result.new(path: path, owner: :work_unit, group: group)
    end

    private

    attr_reader :path
  end
end
