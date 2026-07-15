class AddMediaIdsToChatProposals < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:chat_proposals, :media_ids)
      add_column :chat_proposals, :media_ids, :json
      execute "UPDATE chat_proposals SET media_ids = '[]' WHERE media_ids IS NULL"
      change_column_null :chat_proposals, :media_ids, false
    end
  end

  def down
    remove_column :chat_proposals, :media_ids if column_exists?(:chat_proposals, :media_ids)
  end
end
