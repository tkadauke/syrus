class RemoveInheritedEpicDependencyPolicy < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:epics, :epic_dependency_policy)

    if column_exists?(:repositories, :epic_dependency_policy)
      execute <<~SQL.squish
        UPDATE epics
        SET epic_dependency_policy = COALESCE(
          (
            SELECT repositories.epic_dependency_policy
            FROM repositories
            WHERE repositories.id = epics.repository_id
          ),
          'linear'
        )
        WHERE epic_dependency_policy = 'inherit'
      SQL
    else
      execute "UPDATE epics SET epic_dependency_policy = 'linear' WHERE epic_dependency_policy = 'inherit'"
    end

    change_column_default :epics, :epic_dependency_policy, from: "inherit", to: "linear"
  end

  def down
    change_column_default :epics, :epic_dependency_policy, from: "linear", to: "inherit" if column_exists?(:epics, :epic_dependency_policy)
  end
end
