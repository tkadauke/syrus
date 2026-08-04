class AddRepairAuditToChatPendingActions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_pending_actions, :reason, :text unless column_exists?(:chat_pending_actions, :reason)
    add_snapshot_column(:before_snapshot)
    add_snapshot_column(:after_snapshot)
  end

  def down
    remove_column :chat_pending_actions, :after_snapshot if column_exists?(:chat_pending_actions, :after_snapshot)
    remove_column :chat_pending_actions, :before_snapshot if column_exists?(:chat_pending_actions, :before_snapshot)
    remove_column :chat_pending_actions, :reason if column_exists?(:chat_pending_actions, :reason)
  end

  private

  def add_snapshot_column(name)
    return if column_exists?(:chat_pending_actions, name)

    add_column :chat_pending_actions, name, :json
    execute("UPDATE chat_pending_actions SET #{name} = '{}' WHERE #{name} IS NULL")
    change_column_null :chat_pending_actions, name, false
  end
end
