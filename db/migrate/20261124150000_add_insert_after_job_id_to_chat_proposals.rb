class AddInsertAfterJobIdToChatProposals < ActiveRecord::Migration[8.1]
  def change
    # The existing Epic Job a proposed Job (or an Epic card's head Job) is
    # spliced in after, instead of being appended at the Epic's tail.
    add_column :chat_proposals, :insert_after_job_id, :integer unless column_exists?(:chat_proposals, :insert_after_job_id)
  end
end
