class CreateChatMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_messages do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.string :role, null: false
      t.json :content, null: false
      t.string :tool_name
      t.string :tool_use_id
      t.references :proposal, foreign_key: { to_table: :chat_proposals }

      t.timestamps
    end

    add_index :chat_messages, [ :chat_session_id, :created_at ]
  end
end
