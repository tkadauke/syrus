# The GET request/reset pages are served by the React SPA (SpaController)
# backed by the /api/v1/app/auth JSON endpoints; this controller remains as
# the no-JS form-POST fallback.
class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ update ]
  rate_limit to: 10, within: 3.minutes, only: :create, if: -> { AuthRateLimit.enabled? },
             with: -> { redirect_to new_password_path, alert: I18n.t("passwords.rate_limited") }

  def create
    if user = User.find_by(email_address: params[:email_address])
      PasswordsMailer.reset(user).deliver_later
    end

    redirect_to new_session_path, notice: t("passwords.reset_sent")
  end

  def update
    if @user.update(params.permit(:password, :password_confirmation))
      @user.sessions.destroy_all
      redirect_to new_session_path, notice: t("passwords.reset_success")
    else
      redirect_to edit_password_path(params[:token]), alert: t("passwords.mismatch")
    end
  end

  private
    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to new_password_path, alert: t("passwords.token_invalid")
    end
end
