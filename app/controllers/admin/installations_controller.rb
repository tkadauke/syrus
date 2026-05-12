module Admin
  class InstallationsController < BaseController
    def index
      @settings = AppSetting.current
      @repositories = Repository.includes(:user, :installation).order(:owner, :name)
      @pat_repositories_by_owner = @repositories
        .reject(&:app_credential_active?)
        .group_by { |repository| repository.owner.downcase }
    end

    def refresh
      SyncInstallationsJob.perform_later(Current.user.id)
      redirect_to admin_installations_path, notice: "Installation sync queued."
    end
  end
end
