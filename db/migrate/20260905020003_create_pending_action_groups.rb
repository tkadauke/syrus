class CreatePendingActionGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_action_groups, if_not_exists: true do |t|
      t.integer :chat_session_id, null: false
      t.integer :repository_id
      t.integer :user_id, null: false
      t.text :reason
      t.string :state, default: "pending", null: false
      t.datetime :confirmed_at
      t.datetime :rejected_at

      t.timestamps
    end

    unless index_exists?(:pending_action_groups, :chat_session_id)
      add_index :pending_action_groups, :chat_session_id
    end
    unless index_exists?(:pending_action_groups, [ :chat_session_id, :state ])
      add_index :pending_action_groups, [ :chat_session_id, :state ]
    end
    unless index_exists?(:pending_action_groups, :repository_id)
      add_index :pending_action_groups, :repository_id
    end
    unless index_exists?(:pending_action_groups, :user_id)
      add_index :pending_action_groups, :user_id
    end

    unless column_exists?(:chat_pending_actions, :pending_action_group_id)
      add_column :chat_pending_actions, :pending_action_group_id, :bigint
    end
    unless index_exists?(:chat_pending_actions, :pending_action_group_id)
      add_index :chat_pending_actions, :pending_action_group_id, name: "index_chat_pending_actions_on_pending_action_group_id"
    end
  end
end
