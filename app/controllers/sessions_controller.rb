# The GET sign-in page is served by the React SPA (SpaController) backed by
# the /api/v1/app/auth JSON endpoints; this controller remains as the no-JS
# form-POST fallback.
class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ create ]
  rate_limit to: 10, within: 3.minutes, only: :create, if: -> { AuthRateLimit.enabled? },
             with: -> { redirect_to new_session_path, alert: I18n.t("sessions.rate_limited") }

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: t("sessions.invalid_credentials")
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
