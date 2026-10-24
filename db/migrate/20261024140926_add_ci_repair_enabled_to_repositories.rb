class AddCiRepairEnabledToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :ci_repair_enabled, :boolean, default: true, null: false unless column_exists?(:repositories, :ci_repair_enabled)
  end
end
