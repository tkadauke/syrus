class ChatScopedEvent < ApplicationRecord
  DELIVERY_STATES = %w[pending delivered].freeze
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

  def self.record!(chat_session:, source_kind:, payload:, repository: nil, job: nil, epic: nil, proposal: nil, dedupe_key: nil)
    normalized_dedupe_key = dedupe_key.to_s.presence
    if normalized_dedupe_key
      existing = find_by(chat_session: chat_session, dedupe_key: normalized_dedupe_key)
      return existing if existing
    end

    create!(
      chat_session: chat_session,
      source_kind: source_kind,
      payload: payload,
      repository: repository,
      job: job,
      epic: epic,
      proposal: proposal,
      dedupe_key: normalized_dedupe_key
    )
  rescue ActiveRecord::RecordNotUnique
    find_by!(chat_session: chat_session, dedupe_key: normalized_dedupe_key)
  end

  def mark_delivered!(chat_message:)
    update!(
      delivery_state: "delivered",
      delivered_at: Time.current,
      chat_message: chat_message
    )
  end
end
