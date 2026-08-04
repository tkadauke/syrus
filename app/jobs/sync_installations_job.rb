class SyncInstallationsJob < ApplicationJob
  queue_as :polling

  def perform(default_user_id = nil)
    return unless AppSetting.github_app_registered?

    default_user = User.find_by(id: default_user_id) if default_user_id
    GithubAppInstallationSyncer.new(default_user: default_user).sync
  end
end
