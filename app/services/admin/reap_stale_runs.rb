module Admin
  class ReapStaleRuns
    Result = Data.define(:message, :issues_count, :repairs_count)

    def self.call(source:)
      result = WorkEngine::Reconciler.call_locked!(
        source: source,
        execute_repairs: true
      )
      unless result
        return Result.new(message: "A concurrent reconciliation is already running; try again shortly.", issues_count: 0, repairs_count: 0)
      end

      Result.new(
        message: "WorkEngine reconciler ran inline.",
        issues_count: result.issues.size,
        repairs_count: result.repair_executions.size
      )
    end
  end
end
