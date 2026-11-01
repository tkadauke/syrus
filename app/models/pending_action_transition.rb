class PendingActionTransition < ApplicationRecord
  belongs_to :chat_pending_action, inverse_of: :transitions
  belongs_to :pending_action_item, optional: true, inverse_of: :transitions
  belongs_to :actor, polymorphic: true, optional: true

  attribute :metadata, :json, default: -> { {} }

  validates :sequence, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :chat_pending_action_id }
  validates :event_type, :to_state, presence: true
  validate :item_belongs_to_action

  before_validation :assign_sequence, on: :create
  before_update { raise ActiveRecord::ReadOnlyRecord, "PendingActionTransition is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "PendingActionTransition is append-only" }

  private

  def assign_sequence
    self.sequence ||= chat_pending_action.transitions.maximum(:sequence).to_i + 1
  end

  def item_belongs_to_action
    return unless pending_action_item && chat_pending_action
    return if pending_action_item.chat_pending_action_id == chat_pending_action_id

    errors.add(:pending_action_item, "must belong to the pending action")
  end
end
