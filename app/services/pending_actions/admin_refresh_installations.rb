module PendingActions
  class AdminRefreshInstallations < Base
    action_key "admin_refresh_installations"

    def execute
      SyncInstallationsJob.perform_later(user.id)
      nil
    end
  end
end
