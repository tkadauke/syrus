class MakeChatPendingActionsRepositoryOptional < ActiveRecord::Migration[8.1]
  def up
    change_column_null :chat_pending_actions, :repository_id, true if column_exists?(:chat_pending_actions, :repository_id)
  end

  def down
    change_column_null :chat_pending_actions, :repository_id, false if column_exists?(:chat_pending_actions, :repository_id)
  end
end
