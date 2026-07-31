class CreateScheduledChatMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :scheduled_chat_messages do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :body, null: false
      t.datetime :fire_at, null: false
      t.datetime :sent_at

      t.timestamps
    end

    add_index :scheduled_chat_messages, [ :sent_at, :fire_at ]
  end
end
