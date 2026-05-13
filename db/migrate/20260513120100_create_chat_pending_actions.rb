class CreateChatPendingActions < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_pending_actions do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.string :action, null: false
      t.json :payload, null: false
      t.string :state, null: false, default: "pending"
      t.string :requested_by, null: false, default: "agent"
      t.datetime :confirmed_at
      t.datetime :rejected_at
      t.timestamps
    end

    add_index :chat_pending_actions, [ :chat_session_id, :state, :created_at ]
  end
end
