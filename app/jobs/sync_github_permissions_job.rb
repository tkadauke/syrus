class SyncGithubPermissionsJob < ApplicationJob
  queue_as :polling

  def perform
    return unless AppSetting.github_app_registered?

    GithubPermissionSyncer.new.sync
  end
end
