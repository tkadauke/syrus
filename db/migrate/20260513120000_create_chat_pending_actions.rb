class CreateChatPendingActions < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_pending_actions do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :repository, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :action
      t.string :action_type
      t.json :payload, null: false
      t.string :state, null: false, default: "pending"
      t.string :requested_by, null: false, default: "agent"
      t.datetime :confirmed_at
      t.datetime :rejected_at
      t.datetime :cancelled_at
      t.string :result_type
      t.bigint :result_id

      t.timestamps
    end

    add_index :chat_pending_actions, [ :chat_session_id, :state ]
    add_index :chat_pending_actions, [ :chat_session_id, :state, :created_at ], name: "index_chat_pending_actions_on_session_state"
    add_index :chat_pending_actions, [ :result_type, :result_id ]
  end
end
