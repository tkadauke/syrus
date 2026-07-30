class AddExternalPrUniqueIndexToJobs < ActiveRecord::Migration[8.1]
  def up
    unless index_exists?(:jobs, [:repository_id, :external_pr_number], name: "index_jobs_on_repository_id_and_external_pr_number_unique")
      add_index :jobs, [:repository_id, :external_pr_number],
                unique: true,
                name: "index_jobs_on_repository_id_and_external_pr_number_unique"
    end
  end

  def down
    remove_index :jobs, name: "index_jobs_on_repository_id_and_external_pr_number_unique",
                 if_exists: true
  end
end
