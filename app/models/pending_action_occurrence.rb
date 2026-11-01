class PendingActionOccurrence < ApplicationRecord
  belongs_to :chat_pending_action, inverse_of: :occurrences
  belongs_to :origin, polymorphic: true

  attribute :metadata, :json, default: -> { {} }

  validates :origin_id, uniqueness: { scope: %i[chat_pending_action_id origin_type] }
  validate :authorization_request

  private

  def authorization_request
    return if chat_pending_action&.authorization_request?

    errors.add(:chat_pending_action, "must be an authorization request")
  end
end
