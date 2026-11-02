class AddOutcomeDeliveryToChatPendingActions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_pending_actions, :dismissed_at, :datetime unless column_exists?(:chat_pending_actions, :dismissed_at)
    unless column_exists?(:chat_pending_actions, :outcome_message_id)
      add_reference :chat_pending_actions, :outcome_message, foreign_key: { to_table: :chat_messages }
    end

    add_column :pending_action_groups, :dismissed_at, :datetime unless column_exists?(:pending_action_groups, :dismissed_at)
    unless column_exists?(:pending_action_groups, :outcome_message_id)
      add_reference :pending_action_groups, :outcome_message, foreign_key: { to_table: :chat_messages }
    end
  end
end
