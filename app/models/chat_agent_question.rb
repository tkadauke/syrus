class ChatAgentQuestion < ApplicationRecord
  attribute :questions, :json
  attribute :answers, :json

  belongs_to :chat_session

  after_commit :broadcast_app_event

  validates :asked_at, presence: true
  validate :questions_are_well_formed

  scope :active, -> { where(answered_at: nil, expired_at: nil).order(:asked_at, :id) }

  def active?
    answered_at.blank? && expired_at.blank?
  end

  # answers is index-aligned with questions: one entry per sub-question,
  # each a non-blank string (single-select/free-text) or a non-empty array
  # of strings (multi-select).
  def answer_and_record!(answers, sender_user: nil)
    normalized_answers = normalize_answers(answers)
    return false unless normalized_answers

    enqueue_turn = false
    user_message_id = nil

    with_lock do
      return false unless active?

      enqueue_turn = !chat_session.agent_busy?
      now = Time.current
      user_message = chat_session.messages.create!(
        role: "user",
        content: { "text" => combined_answer_text(normalized_answers) },
        sender_user: sender_user
      )
      user_message_id = user_message.id
      chat_session.update!(last_message_at: now, title: chat_session.title.presence)
      chat_session.pin_chat_provider!
      update!(answers: normalized_answers, answered_at: now)
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

  # Validates each answer against its matching question: present and a
  # string for single-select/free-text, or a non-empty array of non-blank
  # strings for multi-select. Returns nil (invalid) or the normalized array.
  def normalize_answers(answers)
    return nil unless answers.is_a?(Array) && answers.length == questions.length

    normalized = questions.each_with_index.map do |sub_question, index|
      raw_answer = answers[index]

      if sub_question["multiple"]
        return nil unless raw_answer.is_a?(Array)

        normalized_values = raw_answer.map { |value| value.to_s.strip }.reject(&:blank?)
        return nil if normalized_values.empty?

        normalized_values
      else
        text = raw_answer.to_s.strip
        return nil if text.blank?

        text
      end
    end

    normalized
  end

  def combined_answer_text(normalized_answers)
    questions.each_with_index.map do |sub_question, index|
      answer = normalized_answers[index]
      answer_text = answer.is_a?(Array) ? answer.join(", ") : answer
      "Q#{index + 1}: #{sub_question['question']}\nA#{index + 1}: #{answer_text}"
    end.join("\n\n")
  end

  def questions_are_well_formed
    unless questions.is_a?(Array) && questions.present? && questions.length <= 4
      errors.add(:questions, "must be an array of 1 to 4 questions")
      return
    end

    questions.each do |sub_question|
      unless sub_question.is_a?(Hash) && sub_question["question"].is_a?(String) && sub_question["question"].strip.present?
        errors.add(:questions, "each question must have non-blank text")
        next
      end

      options = sub_question["options"]
      unless options.nil? || (options.is_a?(Array) && options.all? { |option| option.is_a?(String) && option.strip.present? })
        errors.add(:questions, "options must be an array of non-empty strings")
      end

      if sub_question["multiple"] && options.blank?
        errors.add(:questions, "multiple-select questions require options")
      end
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
