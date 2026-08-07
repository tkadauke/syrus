module Admin
  class ReapStaleRuns
    Result = Data.define(:message, :issues_count, :repairs_count)

    def self.call(source:)
      result = WorkEngine::Reconciler.call(
        source: source,
        execute_repairs: true
      )
      Result.new(
        message: "WorkEngine reconciler ran inline.",
        issues_count: result.issues.size,
        repairs_count: result.repair_executions.size
      )
    end
  end
end
