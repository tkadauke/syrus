class AddHealthColumnsToRepositories < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:repositories, :ci_health)
      add_column :repositories, :ci_health, :string, null: false, default: "unknown"
    end
    unless column_exists?(:repositories, :grader_health)
      add_column :repositories, :grader_health, :string, null: false, default: "unknown"
    end
    unless column_exists?(:repositories, :last_health_checked_sha)
      add_column :repositories, :last_health_checked_sha, :string
    end
  end

  def down
    remove_column :repositories, :ci_health if column_exists?(:repositories, :ci_health)
    remove_column :repositories, :grader_health if column_exists?(:repositories, :grader_health)
    remove_column :repositories, :last_health_checked_sha if column_exists?(:repositories, :last_health_checked_sha)
  end
end
