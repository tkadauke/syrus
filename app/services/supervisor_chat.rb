class SupervisorChat
  TITLE = "Supervisor".freeze

  def self.ensure_for!(admin_user)
    new(admin_user).ensure_for!
  end

  def initialize(admin_user)
    @admin_user = admin_user
  end

  def ensure_for!
    raise ArgumentError, "Supervisor chat requires an admin user" unless admin_user&.admin?

    chat = nil
    now = Time.current
    ChatSession.transaction(requires_new: true) do
      chat = admin_user.chat_sessions.find_or_create_by!(system_kind: "supervisor") do |session|
        session.title = TITLE
        session.pinned = true
        session.last_message_at = now
      end
    end

    repair_affordance!(chat)
    chat.reload
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  private

  attr_reader :admin_user

  def repair_affordance!(chat)
    updates = {}
    updates[:title] = TITLE if chat.title != TITLE
    updates[:pinned] = true unless chat.pinned?
    updates[:hidden_at] = nil if chat.hidden_at.present?
    updates[:last_message_at] = Time.current if chat.last_message_at.blank?
    return if updates.blank?

    chat.update_columns(updates.merge(updated_at: Time.current))
  end
end
