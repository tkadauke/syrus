module AppApi
  class MeSerializer
    def initialize(user:)
      @user = user
    end

    def as_json(*)
      {
        current_user: current_user_payload,
        team_user_count: User.count,
        unread_notifications_count: unread_notifications_count
      }
    end

    private

    attr_reader :user

    def current_user_payload
      {
        id: user.id,
        email_address: user.email_address,
        display_name: user.display_name,
        admin: user.admin?,
        role: user.role,
        theme: user.theme,
        color_theme_id: user.color_theme_id,
        color_theme: user.color_theme&.public_payload,
        locale: user.locale,
        agent_provider: user.agent_provider,
        chat_provider: user.chat_provider,
        seen_tours: user.seen_tours,
        sidebar_nav_order: user.sidebar_nav_order,
        mobile_chat_auto_hide_header: user.mobile_chat_auto_hide_header?
      }
    end

    def unread_notifications_count
      return user.notifications.where(read_at: nil).count if user.respond_to?(:notifications)
      return ::Notification.where(user: user, read_at: nil).count if defined?(::Notification)

      0
    end
  end
end
