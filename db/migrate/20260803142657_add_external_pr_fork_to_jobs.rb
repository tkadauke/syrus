class AddExternalPrForkToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :external_pr_fork, :boolean, default: false unless column_exists?(:jobs, :external_pr_fork)
  end

  def down
    remove_column :jobs, :external_pr_fork if column_exists?(:jobs, :external_pr_fork)
  end
end
