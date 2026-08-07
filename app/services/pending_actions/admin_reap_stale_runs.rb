module PendingActions
  class AdminReapStaleRuns < Base
    action_key "admin_reap_stale_runs"

    def execute
      WorkEngine::Reconciler.request(source: self.class.name)
      nil
    end
  end
end
