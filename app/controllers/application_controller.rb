class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :compute_system_alerts
  around_action :switch_locale
  helper_method :current_user, :default_chat_path

  private

  # Populate the layout's alert banner area. Computed every request
  # rather than cached — alert sources are cheap (column reads) and
  # we want the banner to disappear the moment the operator fixes
  # the underlying problem (e.g. updates their GH token).
  def compute_system_alerts
    @system_alerts = SystemAlerts.active_for(user: Current.user)
  end

  def switch_locale(&action)
    locale = Current.user&.locale.presence || I18n.default_locale
    I18n.with_locale(locale, &action)
  end

  def require_admin
    return if Current.user&.admin?
    redirect_to root_path, alert: "Admin access required."
  end

  def current_user
    Current.user
  end

  def default_chat_path
    return new_session_path unless Current.user

    chat_session = Current.user.chat_sessions
      .order(Arel.sql("last_message_at IS NULL ASC"), last_message_at: :desc, created_at: :desc, id: :desc)
      .first

    chat_session ? chat_path(chat_session) : dashboard_path
  end
end
