class AddFirstEmptyCiObservationToRepositories < ActiveRecord::Migration[8.1]
  def up
    add_column :repositories, :first_empty_ci_observed_sha, :string unless column_exists?(:repositories, :first_empty_ci_observed_sha)
    add_column :repositories, :first_empty_ci_observed_at, :datetime unless column_exists?(:repositories, :first_empty_ci_observed_at)
  end

  def down
    remove_column :repositories, :first_empty_ci_observed_at if column_exists?(:repositories, :first_empty_ci_observed_at)
    remove_column :repositories, :first_empty_ci_observed_sha if column_exists?(:repositories, :first_empty_ci_observed_sha)
  end
end
