class AddLinkedChatIdToJobs < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:jobs, :linked_chat_id)
      add_reference :jobs, :linked_chat, foreign_key: { to_table: :chat_sessions }, null: true
    end
  end

  def down
    remove_reference :jobs, :linked_chat if column_exists?(:jobs, :linked_chat_id)
  end
end
