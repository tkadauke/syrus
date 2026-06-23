class AddDependsOnEpicIdToJobDependencies < ActiveRecord::Migration[8.1]
  def up
    add_reference :job_dependencies, :depends_on_epic, null: true, foreign_key: { to_table: :epics } unless column_exists?(:job_dependencies, :depends_on_epic_id)
  end

  def down
    remove_reference :job_dependencies, :depends_on_epic, foreign_key: { to_table: :epics } if column_exists?(:job_dependencies, :depends_on_epic_id)
  end
end
