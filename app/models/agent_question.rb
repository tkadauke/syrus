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

    resolve_and_resume! do
      next false unless active?
      update!(answers: normalized, answered_at: Time.current, answered_by: answered_by, answer_source: source.to_s)
    end
  end

  def timeout!
    resolve_and_resume! do
      next false unless active? && times_out_at&.past?

      normalized = normalize_answers(defaults)
      next false unless normalized

      update!(
        answers: normalized,
        answered_at: Time.current,
        answered_by: nil,
        answer_source: "timeout",
        timed_out_at: Time.current
      )
    end
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

  # Records the resolution and resumes the parked Run in one transaction: a
  # resume that raises rolls the answer back, so the question stays active
  # instead of being consumed by a Run that never resumed. The Run's ancestry
  # is locked before the question (parents before children, NY40).
  def resolve_and_resume!
    resume = nil
    resolved = self.class.transaction do
      Lineage.lock!(run) if run
      lock!
      next false unless yield

      resume = AgentQuestions::Resume.new(self) if run_id
      resume = nil if resume && !resume.transition!
      true
    end
    return false unless resolved

    resume&.reenqueue!
    true
  end

  def record_event!(event_type, source:)
    events.create!(event_type: event_type, source: source.presence || @withdraw_source || "unknown", occurred_at: Time.current,
      payload: { "run_id" => run_id, "chat_session_id" => chat_session_id, "answered_by_id" => answered_by_id }.compact)
  end

  def exactly_one_owner
    errors.add(:base, I18n.t("agent_questions.errors.exactly_one_owner")) unless [ chat_session_id, run_id ].compact.one?
  end

  def questions_are_well_formed
    errors.add(:questions, I18n.t("agent_questions.errors.questions_malformed")) unless self.class.normalize_questions(questions) == questions
  end

  def defaults_match_questions
    return if defaults.nil?
    errors.add(:defaults, I18n.t("agent_questions.errors.defaults_malformed")) unless normalize_answers(defaults)
  end
end
