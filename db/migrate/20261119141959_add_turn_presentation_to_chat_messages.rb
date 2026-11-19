class AddTurnPresentationToChatMessages < ActiveRecord::Migration[8.1]
  def up
    add_reference :chat_messages, :turn_message, null: true, foreign_key: false unless column_exists?(:chat_messages, :turn_message_id)
    add_column :chat_messages, :assistant_presentation, :string unless column_exists?(:chat_messages, :assistant_presentation)
  end

  def down
    remove_column :chat_messages, :assistant_presentation if column_exists?(:chat_messages, :assistant_presentation)
    remove_reference :chat_messages, :turn_message, foreign_key: false if column_exists?(:chat_messages, :turn_message_id)
  end
end
