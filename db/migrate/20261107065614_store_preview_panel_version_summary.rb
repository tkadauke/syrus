class StorePreviewPanelVersionSummary < ActiveRecord::Migration[8.1]
  def change
    add_column :preview_panel_versions, :file_count, :integer, null: false, default: 0
    add_column :preview_panel_versions, :entry_viewer_kind, :string, null: false, default: "html"

    reversible do |direction|
      direction.up do
        PreviewPanelVersion.reset_column_information
        PreviewPanelVersion.find_each do |version|
          version.update_columns(
            file_count: version.files.count,
            entry_viewer_kind: PreviewPanel::EntryMetadata.viewer_kind(version.entry_file)
          )
        end
      end
    end
  end
end
