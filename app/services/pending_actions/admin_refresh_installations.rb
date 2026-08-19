module PendingActions
  class AdminRefreshInstallations < Base
    action_key "admin_refresh_installations"

    def execute
      progress!("Queueing installation sync...")
      SyncInstallationsJob.perform_later(user.id)
      nil
    end

    def execution_label
      "Refreshing GitHub installations..."
    end
  end
end
