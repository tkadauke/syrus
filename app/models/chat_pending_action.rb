class ChatPendingAction < ApplicationRecord
  ACTIONS = %w[ add_repo_note remove_repo_note ].freeze
  STATES = %w[ pending confirmed rejected ].freeze
  REQUESTED_BY = %w[ agent operator ].freeze

  attribute :payload, :json, default: -> { {} }

  belongs_to :chat_session

  enum :state, STATES.index_with(&:itself), validate: true

  validates :action, presence: true, inclusion: { in: ACTIONS }
  validates :requested_by, presence: true, inclusion: { in: REQUESTED_BY }
  validate :payload_matches_action

  def confirm!
    with_lock do
      return false unless pending?

      ApplicationRecord.transaction do
        apply!
        update!(state: "confirmed", confirmed_at: Time.current)
      end
    end
  end

  def reject!
    with_lock do
      return false unless pending?

      update!(state: "rejected", rejected_at: Time.current)
    end
  end

  private

  def apply!
    case action
    when "add_repo_note"
      chat_session.repository.repository_notes.create!(
        body: payload.fetch("body").to_s,
        author: "agent"
      )
    when "remove_repo_note"
      note = chat_session.repository.repository_notes.active.find(payload.fetch("id"))
      note.remove!
    else
      raise ArgumentError, "unknown pending action: #{action}"
    end
  end

  def payload_matches_action
    case action
    when "add_repo_note"
      errors.add(:payload, "body is required") if payload["body"].to_s.strip.blank?
    when "remove_repo_note"
      errors.add(:payload, "id is required") unless payload["id"].present?
    end
  end
end
