class AddRollbackEpicToJobs < ActiveRecord::Migration[8.1]
  def change
    add_reference :jobs, :rollback_epic, null: true, foreign_key: { to_table: :epics }
  end
end
