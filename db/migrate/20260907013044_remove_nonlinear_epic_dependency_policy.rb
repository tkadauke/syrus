class RemoveNonlinearEpicDependencyPolicy < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE repositories SET epic_dependency_policy = 'linear' WHERE epic_dependency_policy = 'nonlinear'" if column_exists?(:repositories, :epic_dependency_policy)
    execute "UPDATE epics SET epic_dependency_policy = 'linear' WHERE epic_dependency_policy = 'nonlinear'" if column_exists?(:epics, :epic_dependency_policy)
  end

  def down
    # "nonlinear" is retired application-wide; there is nothing to restore.
    # Rows backfilled by #up simply stay "linear".
  end
end
