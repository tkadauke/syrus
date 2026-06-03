class UsersController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]

  before_action :load_invitation, only: %i[ new create ]
  before_action :enforce_signup_gate, only: %i[ new create ]

  def new
    @user = User.new(email_address: @invitation&.email_address)
  end

  def create
    @user = User.new(user_params)
    if @user.save
      @invitation&.accept!
      start_new_session_for(@user)
      redirect_to after_authentication_url, notice: signup_notice
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
    redirect_to new_session_path, alert: "Sign-up is invitation-only — ask the admin for a link."
  end

  def first_signup?
    User.count.zero?
  end

  def signup_notice
    return "Welcome — you're the first user, so you're the admin." if @user.admin?
    "Welcome to Syrus."
  end
end
