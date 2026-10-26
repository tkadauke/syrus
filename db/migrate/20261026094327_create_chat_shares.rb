class CreateChatShares < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:chat_shares)

    create_table :chat_shares do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :target, polymorphic: true, null: false
      t.references :shared_by_user, null: false, foreign_key: true
      t.datetime :created_at, null: false

      t.index %i[chat_session_id target_type target_id], unique: true
    end
  end

  def down
    drop_table :chat_shares if table_exists?(:chat_shares)
  end
end
