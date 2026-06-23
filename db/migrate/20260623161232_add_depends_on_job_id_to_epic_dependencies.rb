class AddDependsOnJobIdToEpicDependencies < ActiveRecord::Migration[8.1]
  def up
    change_column_null :epic_dependencies, :depends_on_epic_id, true if column_exists?(:epic_dependencies, :depends_on_epic_id)
    add_reference :epic_dependencies, :depends_on_job, null: true, foreign_key: { to_table: :jobs } unless column_exists?(:epic_dependencies, :depends_on_job_id)
  end

  def down
    remove_reference :epic_dependencies, :depends_on_job, foreign_key: { to_table: :jobs } if column_exists?(:epic_dependencies, :depends_on_job_id)
    change_column_null :epic_dependencies, :depends_on_epic_id, false if column_exists?(:epic_dependencies, :depends_on_epic_id)
  end
end
