class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :compute_system_alerts
  helper_method :default_chat_path

  private

  # Populate the layout's alert banner area. Computed every request
  # rather than cached — alert sources are cheap (column reads) and
  # we want the banner to disappear the moment the operator fixes
  # the underlying problem (e.g. updates their GH token).
  def compute_system_alerts
    @system_alerts = SystemAlerts.active_for(user: Current.user)
  end

  def require_admin
    return if Current.user&.admin?
    redirect_to root_path, alert: "Admin access required."
  end

  def default_chat_path
    return new_session_path unless Current.user

    chat_session = Current.user.chat_sessions
      .where.not(last_message_at: nil)
      .order(last_message_at: :desc, created_at: :desc, id: :desc)
      .detect(&:repository)

    chat_session ? repository_chats_path(chat_session.repository) : repositories_path
  end
end
