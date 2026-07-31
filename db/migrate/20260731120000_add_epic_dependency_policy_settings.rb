class AddEpicDependencyPolicySettings < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:repositories, :epic_dependency_policy)
      add_column :repositories, :epic_dependency_policy, :string, default: "linear", null: false
    end

    unless column_exists?(:epics, :epic_dependency_policy)
      add_column :epics, :epic_dependency_policy, :string, default: "inherit", null: false
    end
  end

  def down
    remove_column :epics, :epic_dependency_policy if column_exists?(:epics, :epic_dependency_policy)
    remove_column :repositories, :epic_dependency_policy if column_exists?(:repositories, :epic_dependency_policy)
  end
end
