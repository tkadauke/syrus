class AddExternalPrAuthorToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :external_pr_author, :string unless column_exists?(:jobs, :external_pr_author)
  end

  def down
    remove_column :jobs, :external_pr_author if column_exists?(:jobs, :external_pr_author)
  end
end
