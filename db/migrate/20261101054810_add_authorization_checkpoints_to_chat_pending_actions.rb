class AddAuthorizationCheckpointsToChatPendingActions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_pending_actions, :checkpoint_state, :string unless column_exists?(:chat_pending_actions, :checkpoint_state)
    add_column :chat_pending_actions, :checkpoint_payload, :json unless column_exists?(:chat_pending_actions, :checkpoint_payload)
    add_column :chat_pending_actions, :checkpointed_at, :datetime unless column_exists?(:chat_pending_actions, :checkpointed_at)
    add_column :chat_pending_actions, :resume_started_at, :datetime unless column_exists?(:chat_pending_actions, :resume_started_at)
    add_column :chat_pending_actions, :resumed_at, :datetime unless column_exists?(:chat_pending_actions, :resumed_at)
    add_column :chat_pending_actions, :resume_attempts, :integer, null: false, default: 0 unless column_exists?(:chat_pending_actions, :resume_attempts)
    add_column :chat_pending_actions, :last_resume_error, :text unless column_exists?(:chat_pending_actions, :last_resume_error)

    execute "UPDATE chat_pending_actions SET checkpoint_payload = '{}' WHERE checkpoint_payload IS NULL"
    change_column_null :chat_pending_actions, :checkpoint_payload, false

    unless index_exists?(:chat_pending_actions, [ :origin_type, :origin_id, :checkpoint_state ], name: "idx_pending_actions_origin_checkpoint")
      add_index :chat_pending_actions, [ :origin_type, :origin_id, :checkpoint_state ],
        name: "idx_pending_actions_origin_checkpoint"
    end
  end

  def down
    remove_index :chat_pending_actions, name: "idx_pending_actions_origin_checkpoint", if_exists: true
    %i[last_resume_error resume_attempts resumed_at resume_started_at checkpointed_at checkpoint_payload checkpoint_state].each do |column|
      remove_column :chat_pending_actions, column if column_exists?(:chat_pending_actions, column)
    end
  end
end
