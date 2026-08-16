class CreateChatMessagePins < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_message_pins, if_not_exists: true do |t|
      t.references :chat_message, null: false, foreign_key: true

      t.timestamps
    end

    unless index_exists?(:chat_message_pins, [ :chat_message_id, :id ], name: "idx_chat_message_pins_message_id_id")
      add_index :chat_message_pins,
                [ :chat_message_id, :id ],
                name: "idx_chat_message_pins_message_id_id"
    end
  end
end
