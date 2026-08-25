class ChatScopedEvent < ApplicationRecord
  DELIVERY_STATES = %w[pending delivered].freeze
  EVALUATOR_STATES = %w[pending running completed failed].freeze
  MAX_DEDUPE_KEY_LENGTH = 255
  MAX_SOURCE_KIND_LENGTH = 100

  belongs_to :chat_session
  belongs_to :repository, optional: true
  belongs_to :job, optional: true
  belongs_to :epic, optional: true
  belongs_to :proposal, class_name: "ChatProposal", optional: true
  belongs_to :chat_message, optional: true

  validates :source_kind, presence: true, length: { maximum: MAX_SOURCE_KIND_LENGTH }
  validates :delivery_state, presence: true, inclusion: { in: DELIVERY_STATES }
  validates :evaluator_state, presence: true, inclusion: { in: EVALUATOR_STATES }
  validates :dedupe_key, length: { maximum: MAX_DEDUPE_KEY_LENGTH }, allow_nil: true
  validates :payload, presence: true

  scope :pending, -> { where(delivery_state: "pending") }
  scope :delivered, -> { where(delivery_state: "delivered") }

  def pending?
    delivery_state == "pending"
  end

  def delivered?
    delivery_state == "delivered"
  end

  def evaluator_pending?
    evaluator_state == "pending"
  end

  def evaluator_completed?
    evaluator_state == "completed"
  end

  def evaluator_failed?
    evaluator_state == "failed"
  end

  def mark_evaluator_running!(session_id:)
    update!(
      evaluator_state: "running",
      evaluator_session_id: session_id,
      evaluator_error: nil,
      evaluator_result: nil
    )
  end

  def record_evaluator_result!(result)
    update!(
      evaluator_state: "completed",
      evaluator_result: result,
      evaluator_error: nil,
      evaluated_at: Time.current
    )
  end

  def record_evaluator_failure!(error)
    update!(
      evaluator_state: "failed",
      evaluator_error: error.to_s,
      evaluated_at: Time.current
    )
  end

  def retry_evaluator!
    return false unless pending? && evaluator_failed?

    update!(
      evaluator_state: "pending",
      evaluator_session_id: nil,
      evaluator_error: nil,
      evaluator_result: nil,
      evaluated_at: nil
    )
  end

  def self.record!(chat_session:, source_kind:, payload:, repository: nil, job: nil, epic: nil, proposal: nil, dedupe_key: nil)
    normalized_dedupe_key = dedupe_key.to_s.presence
    if normalized_dedupe_key
      existing = find_by(chat_session: chat_session, dedupe_key: normalized_dedupe_key)
      return existing if existing
    end

    attributes = {
      chat_session: chat_session,
      source_kind: source_kind,
      payload: payload,
      repository: repository,
      job: job,
      epic: epic,
      proposal: proposal,
      dedupe_key: normalized_dedupe_key
    }

    attempts = 0
    begin
      create!(attributes)
    rescue ActiveRecord::RecordNotUnique
      raise unless normalized_dedupe_key

      existing = find_by(chat_session: chat_session, dedupe_key: normalized_dedupe_key)
      return existing if existing

      attempts += 1
      retry if attempts < 2

      raise
    end
  end

  def mark_delivered!(chat_message:)
    update!(
      delivery_state: "delivered",
      delivered_at: Time.current,
      chat_message: chat_message
    )
  end
end
