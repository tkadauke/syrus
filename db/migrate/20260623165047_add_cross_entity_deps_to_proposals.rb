class AddCrossEntityDepsToProposals < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_proposals, :depends_on_epic_ids, :json unless column_exists?(:chat_proposals, :depends_on_epic_ids)
    add_column :chat_proposals, :depends_on_job_ids, :json unless column_exists?(:chat_proposals, :depends_on_job_ids)
  end

  def down
    remove_column :chat_proposals, :depends_on_job_ids if column_exists?(:chat_proposals, :depends_on_job_ids)
    remove_column :chat_proposals, :depends_on_epic_ids if column_exists?(:chat_proposals, :depends_on_epic_ids)
  end
end
