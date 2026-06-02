class SpaController < ApplicationController
  layout "spa"
  before_action :resume_session_for_public_path, if: :public_spa_path?
  before_action :enforce_signup_gate, if: :signup_spa_path?
  before_action :require_admin, if: :admin_spa_path?

  def show
    authenticated?
  end

  private

  def require_authentication
    return if public_spa_path?

    super
  end

  def public_spa_path?
    canonical_landing_path? ||
      normalized_path.in?(%w[
        /session/new
        /users/new
        /passwords/new
      ]) ||
      normalized_path.match?(%r{\A/passwords/[^/]+/edit\z})
  end

  def canonical_landing_path?
    request.path == "/" && normalized_path == "/"
  end

  def resume_session_for_public_path
    resume_session
  end

  def signup_spa_path?
    normalized_path == "/users/new"
  end

  def enforce_signup_gate
    return if invitation_from_params&.usable?
    return if User.count.zero?
    return if AppSetting.signups_open?

    redirect_to new_session_path, alert: "Sign-up is invitation-only — ask the admin for a link."
  end

  def invitation_from_params
    token = params[:token].to_s.presence
    return unless token

    Invitation.find_by(token: token)
  end

  def admin_spa_path?
    normalized_path == "/admin" ||
      normalized_path.start_with?("/admin/") ||
      normalized_path == "/invitations" ||
      normalized_path == "/settings/edit"
  end

  def normalized_path
    @normalized_path ||= request.path.sub(/\A\/app-shell/, "").presence || "/"
  end
end
