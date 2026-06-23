class AddEpicDependsOnTokensToChatProposals < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_proposals, :epic_depends_on_tokens, :text unless column_exists?(:chat_proposals, :epic_depends_on_tokens)
  end

  def down
    remove_column :chat_proposals, :epic_depends_on_tokens if column_exists?(:chat_proposals, :epic_depends_on_tokens)
  end
end
