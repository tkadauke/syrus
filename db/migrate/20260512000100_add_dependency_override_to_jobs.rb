class AddDependencyOverrideToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :dependencies_overridden_at, :datetime
    add_reference :jobs, :dependencies_overridden_by_user, foreign_key: { to_table: :users }
  end
end
