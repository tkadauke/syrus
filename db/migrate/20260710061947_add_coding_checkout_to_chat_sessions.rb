class AddCodingCheckoutToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :coding_checkout_branch, :string unless column_exists?(:chat_sessions, :coding_checkout_branch)
    add_column :chat_sessions, :coding_checkout_uncommitted, :boolean, default: false, null: false unless column_exists?(:chat_sessions, :coding_checkout_uncommitted)
  end

  def down
    remove_column :chat_sessions, :coding_checkout_uncommitted if column_exists?(:chat_sessions, :coding_checkout_uncommitted)
    remove_column :chat_sessions, :coding_checkout_branch if column_exists?(:chat_sessions, :coding_checkout_branch)
  end
end
