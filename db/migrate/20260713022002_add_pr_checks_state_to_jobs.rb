class AddPrChecksStateToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :pr_checks_sha, :string unless column_exists?(:jobs, :pr_checks_sha)
    add_column :jobs, :pr_checks_state, :string unless column_exists?(:jobs, :pr_checks_state)
    add_column :jobs, :pr_checks_checked_at, :datetime unless column_exists?(:jobs, :pr_checks_checked_at)
  end

  def down
    remove_column :jobs, :pr_checks_checked_at if column_exists?(:jobs, :pr_checks_checked_at)
    remove_column :jobs, :pr_checks_state if column_exists?(:jobs, :pr_checks_state)
    remove_column :jobs, :pr_checks_sha if column_exists?(:jobs, :pr_checks_sha)
  end
end
