module PendingActions
  class AdminReapStaleRuns < Base
    action_key "admin_reap_stale_runs"

    def execute
      ReapStaleRunsJob.perform_later
      nil
    end
  end
end
