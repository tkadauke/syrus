class CreateChatScratchpadItems < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_scratchpad_items, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.text :content, null: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :chat_scratchpad_items, [ :chat_session_id, :position, :id ], name: "index_chat_scratchpad_items_on_session_position" unless index_exists?(:chat_scratchpad_items, [ :chat_session_id, :position, :id ], name: "index_chat_scratchpad_items_on_session_position")
  end
end
