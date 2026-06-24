class CreateChatWakeups < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_wakeups, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :prompt, null: false
      t.datetime :fire_at, null: false
      t.string :state, null: false, default: "pending"

      t.timestamps
    end

    add_index :chat_wakeups, [ :state, :fire_at ] unless index_exists?(:chat_wakeups, [ :state, :fire_at ])
  end

  def down
    drop_table :chat_wakeups, if_exists: true
  end
end
