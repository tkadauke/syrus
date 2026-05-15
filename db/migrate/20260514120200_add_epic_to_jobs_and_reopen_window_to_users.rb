class AddEpicToJobsAndReopenWindowToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :jobs, :epic, foreign_key: true
    add_column :users, :epic_reopen_window, :integer, default: 30, null: false
  end
end
