class AddRecentChatsGroupSizeToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :recent_chats_group_size, :integer, default: 10, null: false unless column_exists?(:users, :recent_chats_group_size)
  end

  def down
    remove_column :users, :recent_chats_group_size if column_exists?(:users, :recent_chats_group_size)
  end
end
