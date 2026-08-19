module PendingActions
  class AdminReapStaleRuns < Base
    action_key "admin_reap_stale_runs"

    def execute
      progress!("Requesting work-engine reconciliation...")
      WorkEngine::Reconciler.request(source: self.class.name)
      nil
    end

    def execution_label
      "Requesting stale-run reaper..."
    end
  end
end
