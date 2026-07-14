class AddLastGradedShaToRepositories < ActiveRecord::Migration[8.1]
  def up
    add_column :repositories, :last_graded_sha, :string unless column_exists?(:repositories, :last_graded_sha)
  end

  def down
    remove_column :repositories, :last_graded_sha if column_exists?(:repositories, :last_graded_sha)
  end
end
