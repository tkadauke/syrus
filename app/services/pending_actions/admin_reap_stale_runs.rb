module PendingActions
  class AdminReapStaleRuns < Base
    action_key "admin_reap_stale_runs"

    def execute
      if Feature.unified_work_engine_reconciler_enabled?
        WorkEngine::Reconciler.request(source: self.class.name)
      else
        ReapStaleRunsJob.perform_later
      end
      nil
    end
  end
end
