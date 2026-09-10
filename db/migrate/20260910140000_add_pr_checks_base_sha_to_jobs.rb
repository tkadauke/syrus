class AddPrChecksBaseShaToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :pr_checks_base_sha, :string unless column_exists?(:jobs, :pr_checks_base_sha)
  end
end
