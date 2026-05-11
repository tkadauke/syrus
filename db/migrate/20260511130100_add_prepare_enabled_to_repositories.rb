class AddPrepareEnabledToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :prepare_enabled, :boolean, null: false, default: true, if_not_exists: true
  end
end
