class AddTargetRepositoryIdToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :target_repository_id, :bigint unless column_exists?(:jobs, :target_repository_id)
    add_index :jobs, :target_repository_id, name: "index_jobs_on_target_repository_id" unless index_exists?(:jobs, :target_repository_id)
    unless foreign_key_exists?(:jobs, column: :target_repository_id)
      add_foreign_key :jobs, :repositories, column: :target_repository_id
    end
  end

  def down
    remove_foreign_key :jobs, column: :target_repository_id if foreign_key_exists?(:jobs, column: :target_repository_id)
    remove_index :jobs, :target_repository_id, name: "index_jobs_on_target_repository_id" if index_exists?(:jobs, :target_repository_id)
    remove_column :jobs, :target_repository_id if column_exists?(:jobs, :target_repository_id)
  end
end
