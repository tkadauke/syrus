class AddExternalPrIngestionEnabledToRepositories < ActiveRecord::Migration[8.1]
  def up
    add_column :repositories, :external_pr_ingestion_enabled, :boolean unless column_exists?(:repositories, :external_pr_ingestion_enabled)
    execute "UPDATE repositories SET external_pr_ingestion_enabled = 0 WHERE external_pr_ingestion_enabled IS NULL"
    change_column_null :repositories, :external_pr_ingestion_enabled, false
  end

  def down
    remove_column :repositories, :external_pr_ingestion_enabled if column_exists?(:repositories, :external_pr_ingestion_enabled)
  end
end
