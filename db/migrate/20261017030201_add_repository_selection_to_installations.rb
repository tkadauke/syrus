class AddRepositorySelectionToInstallations < ActiveRecord::Migration[8.1]
  def change
    add_column :installations, :repository_selection, :string, default: "all", null: false unless column_exists?(:installations, :repository_selection)
    add_column :installations, :selected_repository_ids, :json unless column_exists?(:installations, :selected_repository_ids)
  end
end
