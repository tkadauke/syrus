class AddProviderSettingToChatProposals < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_proposals, :provider_setting, :string, null: false, default: "default" unless column_exists?(:chat_proposals, :provider_setting)

    execute "UPDATE chat_proposals SET provider_setting = 'default' WHERE provider_setting IS NULL"
  end

  def down
    remove_column :chat_proposals, :provider_setting if column_exists?(:chat_proposals, :provider_setting)
  end
end
