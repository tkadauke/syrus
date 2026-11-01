class AddRollbackEpicToJobs < ActiveRecord::Migration[8.1]
  def change
    add_reference :jobs, :rollback_epic, null: true unless column_exists?(:jobs, :rollback_epic_id)
  end
end
