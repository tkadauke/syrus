class AddGithubIdsToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :github_repository_id, :bigint
    add_column :repositories, :github_owner_id, :bigint

    add_index :repositories, :github_repository_id
    add_index :repositories, :github_owner_id
  end
end
