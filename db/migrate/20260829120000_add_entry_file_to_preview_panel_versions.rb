class AddEntryFileToPreviewPanelVersions < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:preview_panel_versions, :entry_file)
      add_column :preview_panel_versions, :entry_file, :string, null: false, default: "index.html"
    end
  end
end
