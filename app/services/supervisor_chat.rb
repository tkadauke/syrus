class SupervisorChat
  TITLE = "Supervisor".freeze
  KICKOFF_SOURCE = "supervisor_kickoff".freeze
  KICKOFF_TEXT = <<~TEXT.squish.freeze
    Start Supervisor operations triage. Review current Syrus operational state,
    summarize incidents or blocked work that need admin attention, and recommend
    concrete next actions for Jobs, Workflows, Runs, queues, repositories, users,
    or worker processes. Do not treat missing repository attachment as a blocker;
    ask for repository attachment only if I explicitly request code inspection,
    proposal drafting, or another repository-context-dependent task.
  TEXT

  def self.ensure_for!(admin_user)
    new(admin_user).ensure_for!
  end

  def initialize(admin_user)
    @admin_user = admin_user
  end

  def ensure_for!
    raise ArgumentError, "Supervisor chat requires an admin user" unless admin_user&.admin?

    chat = nil
    kickoff_message = nil
    now = Time.current
    ChatSession.transaction(requires_new: true) do
      chat = admin_user.chat_sessions.find_or_create_by!(system_kind: "supervisor") do |session|
        session.title = TITLE
        session.pinned = true
        session.last_message_at = now
      end

      chat.lock!
      repair_affordance!(chat)
      kickoff_message = ensure_kickoff_message!(chat)
    end

    ChatTurnJob.perform_later(chat.id, kickoff_message.id) if kickoff_message
    chat.reload
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  private

  attr_reader :admin_user

  def ensure_kickoff_message!(chat)
    return if kickoff_message?(chat)

    message = chat.messages.create!(
      role: "user",
      content: {
        "text" => KICKOFF_TEXT,
        "source" => KICKOFF_SOURCE
      }
    )
    chat.update_columns(last_read_at: message.created_at)
    chat.last_read_at = message.created_at
    chat.pin_chat_provider!(broadcast: false)
    message
  end

  def kickoff_message?(chat)
    chat.messages.where(role: "user").any? do |message|
      content = message.content
      content.is_a?(Hash) && content["source"] == KICKOFF_SOURCE
    end
  end

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
