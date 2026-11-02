class BackfillPendingActionOutcomeDeliveryMarkers < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_pending_actions, :outcome_wake_enqueued_at, :datetime unless column_exists?(:chat_pending_actions, :outcome_wake_enqueued_at)
    add_column :chat_pending_actions, :legacy_outcome, :boolean, default: false, null: false unless column_exists?(:chat_pending_actions, :legacy_outcome)
    add_column :pending_action_groups, :outcome_wake_enqueued_at, :datetime unless column_exists?(:pending_action_groups, :outcome_wake_enqueued_at)
    add_column :pending_action_groups, :legacy_outcome, :boolean, default: false, null: false unless column_exists?(:pending_action_groups, :legacy_outcome)

    execute <<~SQL.squish
      UPDATE chat_pending_actions
      SET dismissed_at = COALESCE(dismissed_at, updated_at), legacy_outcome = TRUE
      WHERE state IN ('confirmed', 'rejected', 'cancelled', 'failed')
        AND legacy_outcome = FALSE
        AND outcome_message_id IS NULL
    SQL
    execute <<~SQL.squish
      UPDATE pending_action_groups
      SET dismissed_at = COALESCE(dismissed_at, updated_at), legacy_outcome = TRUE
      WHERE state IN ('confirmed', 'rejected', 'dismissed')
        AND legacy_outcome = FALSE
        AND outcome_message_id IS NULL
    SQL
  end

  def down
    # The original migration may already have installed these columns. Removing
    # them here would make rolling back this compatibility migration destructive.
  end
end
