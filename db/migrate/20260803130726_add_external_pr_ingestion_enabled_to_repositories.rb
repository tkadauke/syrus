class AddExternalPrIngestionEnabledToRepositories < ActiveRecord::Migration[8.1]
  def up
    add_column :repositories, :external_pr_ingestion_enabled, :boolean, default: false, null: false unless column_exists?(:repositories, :external_pr_ingestion_enabled)
  end

  def down
    remove_column :repositories, :external_pr_ingestion_enabled if column_exists?(:repositories, :external_pr_ingestion_enabled)
  end
end
