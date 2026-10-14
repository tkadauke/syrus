# The GET sign-up page is served by the React SPA (SpaController) backed by
# the /api/v1/app/auth JSON endpoints; this controller remains as the no-JS
# form-POST fallback.
class UsersController < ApplicationController
  allow_unauthenticated_access only: %i[ create ]

  before_action :load_invitation, only: %i[ create ]
  before_action :enforce_signup_gate, only: %i[ create ]

  def create
    result = Signups::Creator.call(attributes: user_params, invitation: @invitation)
    @user = result.user

    if result.created?
      start_new_session_for(@user)
      redirect_to after_authentication_url, notice: signup_notice
    elsif result.forbidden?
      redirect_to new_session_path, alert: t("users.signup_invitation_only")
    else
      redirect_to new_user_path(token: @invitation&.token),
                  alert: @user.errors.full_messages.to_sentence,
                  status: :see_other
    end
  end

  private

  def user_params
    params.expect(user: [ :email_address, :password, :password_confirmation ])
  end

  def load_invitation
    token = params[:token].presence || params.dig(:user, :invitation_token).presence
    return unless token
    @invitation = Invitation.find_by(token: token)
  end

  def enforce_signup_gate
    return if @invitation&.usable?
    return if first_signup?
    return if AppSetting.signups_open?
    redirect_to new_session_path, alert: t("users.signup_invitation_only")
  end

  def first_signup?
    User.count.zero?
  end

  def signup_notice
    return t("users.welcome_admin") if @user.admin?
    t("users.welcome")
  end
end
