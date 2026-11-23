class AddLandingConcurrencyToRepositories < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:repositories, :landing_concurrency)
      add_column :repositories, :landing_concurrency, :integer, default: 1, null: false
    end
  end

  def down
    remove_column :repositories, :landing_concurrency if column_exists?(:repositories, :landing_concurrency)
  end
end
