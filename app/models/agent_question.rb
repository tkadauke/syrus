class AgentQuestion < ApplicationRecord
  self.table_name = "chat_agent_questions"

  include AgentQuestionSchema

  attribute :questions, :json
  attribute :answers, :json
  attribute :defaults, :json

  belongs_to :chat_session, optional: true
  belongs_to :response_chat_session, class_name: "ChatSession", optional: true
  belongs_to :run, optional: true
  belongs_to :answered_by, class_name: "User", optional: true
  has_many :events, class_name: "AgentQuestionEvent", dependent: :destroy

  after_create_commit { record_event!("asked", source: run_id ? "workflow" : "chat") }
  after_update_commit -> { record_event!("answered", source: answer_source) }, if: -> { saved_change_to_answered_at? && answered_at.present? }
  after_update_commit -> { record_event!("withdrawn", source: @withdraw_source || "system") }, if: -> { saved_change_to_withdrawn_at? && withdrawn_at.present? }
  after_update_commit -> { record_event!("timed_out", source: "timeout") }, if: -> { saved_change_to_timed_out_at? && timed_out_at.present? }

  validates :asked_at, presence: true
  validate :exactly_one_owner
  validate :questions_are_well_formed
  validate :defaults_match_questions

  scope :active, -> { where(answered_at: nil, expired_at: nil, withdrawn_at: nil).order(:asked_at, :id) }

  def active? = answered_at.blank? && expired_at.blank? && withdrawn_at.blank?

  def answer!(answers:, answered_by:, source:)
    normalized = normalize_answers(answers)
    return false unless normalized && source.to_s.strip.present?

    with_lock do
      return false unless active?
      update!(answers: normalized, answered_at: Time.current, answered_by: answered_by, answer_source: source.to_s)
    end
    AgentQuestions::Resume.call(self) if run_id
    true
  end

  def timeout!
    with_lock do
      return false unless active? && times_out_at&.past?

      normalized = normalize_answers(defaults)
      return false unless normalized

      update!(
        answers: normalized,
        answered_at: Time.current,
        answered_by: nil,
        answer_source: "timeout",
        timed_out_at: Time.current
      )
    end
    AgentQuestions::Resume.call(self) if run_id
    true
  end

  def questions_payload
    Array(questions).each_with_index.map do |question, index|
      { question: question["question"], options: question["options"].presence, multiple: question["multiple"] == true,
        default: Array(defaults)[index] }
    end
  end

  def withdraw!(source: "system")
    with_lock do
      return false unless active?
      self.withdrawn_at = Time.current
      @withdraw_source = source
      save!
    end
    true
  end

  private

  def record_event!(event_type, source:)
    events.create!(event_type: event_type, source: source.presence || @withdraw_source || "unknown", occurred_at: Time.current,
      payload: { "run_id" => run_id, "chat_session_id" => chat_session_id, "answered_by_id" => answered_by_id }.compact)
  end

  def exactly_one_owner
    errors.add(:base, "must belong to either a chat session or a run") unless [ chat_session_id, run_id ].compact.one?
  end

  def questions_are_well_formed
    errors.add(:questions, "must be an array of 1 to 4 well-formed questions") unless self.class.normalize_questions(questions) == questions
  end

  def defaults_match_questions
    return if defaults.nil?
    errors.add(:defaults, "must provide one non-blank default per question") unless normalize_answers(defaults)
  end
end
