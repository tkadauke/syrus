class CreateChatBookmarks < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_bookmarks do |t|
      t.references :chat_message, null: false, foreign_key: true
      t.string :label, null: false
      t.string :kind, null: false

      t.timestamps
    end
  end
end
