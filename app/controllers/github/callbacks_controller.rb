class Github::CallbacksController < ApplicationController
  # GET /github/callback?installation_id=&setup_action=install
  # GitHub redirects here after the user installs (or updates) the App.
  def create
    installation_id = params[:installation_id].to_i
    if installation_id.zero?
      redirect_to edit_credentials_path, alert: "No installation ID received from GitHub."
      return
    end

    GithubInstallation.find_or_initialize_by(user: Current.user)
                      .update!(installation_id: installation_id)

    redirect_to edit_credentials_path, notice: "GitHub App installed successfully."
  end
end
