class CreateChatSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_sessions do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :title
      t.datetime :last_message_at
      t.datetime :stop_requested_at
      t.integer :cumulative_input_tokens, default: 0, null: false
      t.integer :cumulative_output_tokens, default: 0, null: false

      t.timestamps
    end

    add_index :chat_sessions, [ :repository_id, :last_message_at ]
  end
end
