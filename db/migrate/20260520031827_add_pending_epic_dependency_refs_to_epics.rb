class AddPendingEpicDependencyRefsToEpics < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:epics, :pending_epic_dependency_refs)

    add_column :epics, :pending_epic_dependency_refs, :json
    execute "UPDATE epics SET pending_epic_dependency_refs = '[]' WHERE pending_epic_dependency_refs IS NULL"
    change_column_null :epics, :pending_epic_dependency_refs, false
  end

  def down
    remove_column :epics, :pending_epic_dependency_refs if column_exists?(:epics, :pending_epic_dependency_refs)
  end
end
