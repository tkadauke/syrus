module RetentionPolicyExecutors
  class OperationalLogEvent < Default
    def call(...)
      return Result.new(deleted_count: 0, backlog: false) unless OperationalLogging.configured_for_instance?

      cutoff = retention_cutoff
      return Result.new(deleted_count: 0, backlog: false) unless cutoff

      OperationalLogging.suppress do
        OperationalLogIndex.prune_before(cutoff)
        super
      end
    end
  end
end
