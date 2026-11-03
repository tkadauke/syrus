class PendingActionTransition < ApplicationRecord
  belongs_to :chat_pending_action, inverse_of: :transitions
  belongs_to :pending_action_item, optional: true, inverse_of: :transitions
  belongs_to :actor, polymorphic: true, optional: true

  attribute :metadata, :json, default: -> { {} }

  validates :sequence, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :chat_pending_action_id }, unless: :sequence_assigned_under_lock?
  validates :event_type, :to_state, presence: true
  validate :item_belongs_to_action

  before_validation :assign_sequence, on: :create
  before_update { raise ActiveRecord::ReadOnlyRecord, "PendingActionTransition is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "PendingActionTransition is append-only" }

  private

  def assign_sequence
    return if sequence || !chat_pending_action

    chat_pending_action.with_lock do
      self.sequence = chat_pending_action.transitions.maximum(:sequence).to_i + 1
      @sequence_assigned_under_lock = true
    end
  end

  # The sequence was just computed while holding the action's row lock (and
  # idx_pending_action_transitions_sequence is unique), so re-checking
  # uniqueness would only repeat that query.
  def sequence_assigned_under_lock?
    @sequence_assigned_under_lock == true
  end

  def item_belongs_to_action
    return unless pending_action_item && chat_pending_action
    return if pending_action_item.chat_pending_action_id == chat_pending_action_id

    errors.add(:pending_action_item, "must belong to the pending action")
  end
end
