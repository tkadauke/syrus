class AddEntryFileToPreviewPanelVersions < ActiveRecord::Migration[8.1]
  def change
    add_column :preview_panel_versions, :entry_file, :string, null: false, default: "index.html"
  end
end
