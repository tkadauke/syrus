class AddOutcomeDeliveryToChatPendingActions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_pending_actions, :dismissed_at, :datetime unless column_exists?(:chat_pending_actions, :dismissed_at)
    unless column_exists?(:chat_pending_actions, :outcome_message_id)
      add_reference :chat_pending_actions, :outcome_message, foreign_key: false
    end
    add_column :chat_pending_actions, :outcome_wake_enqueued_at, :datetime unless column_exists?(:chat_pending_actions, :outcome_wake_enqueued_at)
    add_column :chat_pending_actions, :legacy_outcome, :boolean, default: false, null: false unless column_exists?(:chat_pending_actions, :legacy_outcome)

    add_column :pending_action_groups, :dismissed_at, :datetime unless column_exists?(:pending_action_groups, :dismissed_at)
    unless column_exists?(:pending_action_groups, :outcome_message_id)
      add_reference :pending_action_groups, :outcome_message, foreign_key: false
    end
    add_column :pending_action_groups, :outcome_wake_enqueued_at, :datetime unless column_exists?(:pending_action_groups, :outcome_wake_enqueued_at)
    add_column :pending_action_groups, :legacy_outcome, :boolean, default: false, null: false unless column_exists?(:pending_action_groups, :legacy_outcome)

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE chat_pending_actions
          SET dismissed_at = COALESCE(dismissed_at, updated_at), legacy_outcome = TRUE
          WHERE state IN ('confirmed', 'rejected', 'cancelled', 'failed')
        SQL
        execute <<~SQL.squish
          UPDATE pending_action_groups
          SET dismissed_at = COALESCE(dismissed_at, updated_at), legacy_outcome = TRUE
          WHERE state IN ('confirmed', 'rejected', 'dismissed')
        SQL
      end
    end
  end
end
