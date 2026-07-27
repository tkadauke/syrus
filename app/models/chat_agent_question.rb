class ChatAgentQuestion < ApplicationRecord
  attribute :options, :json

  belongs_to :chat_session

  after_commit :broadcast_app_event

  validates :question, presence: true
  validates :asked_at, presence: true
  validate :options_are_strings

  scope :active, -> { where(answered_at: nil, expired_at: nil).order(:asked_at, :id) }

  def active?
    answered_at.blank? && expired_at.blank?
  end

  def answer!(value)
    with_lock do
      return false unless active?

      update!(answer: value.to_s, answered_at: Time.current)
    end
  end

  def answer_and_record!(value)
    enqueue_turn = false
    user_message_id = nil

    with_lock do
      return false unless active?

      enqueue_turn = !chat_session.agent_busy?
      now = Time.current
      user_message = chat_session.messages.create!(role: "user", content: { "text" => value.to_s })
      user_message_id = user_message.id
      chat_session.update!(last_message_at: now, title: chat_session.title.presence)
      update!(answer: value.to_s, answered_at: now)
    end

    ChatTurnJob.perform_later(chat_session_id, user_message_id) if enqueue_turn
    true
  end

  def expire!
    with_lock do
      return false unless active?

      update!(expired_at: Time.current)
    end
  end

  private

  def options_are_strings
    return if options.nil?

    unless options.is_a?(Array) && options.all? { |option| option.is_a?(String) && option.strip.present? }
      errors.add(:options, "must be an array of non-empty strings")
    end
  end

  def broadcast_app_event
    AppEvents.broadcast(
      user: chat_session.user,
      type: "updated",
      resource: "chat",
      id: chat_session_id,
      changed: [ "agent_questions" ],
      payload: {
        action: "update_agent_questions",
        agent_questions: chat_session.agent_questions_payload
      }
    )
  end
end
