class StorePreviewPanelVersionSummary < ActiveRecord::Migration[8.1]
  class Version < ActiveRecord::Base
    self.table_name = "preview_panel_versions"
  end

  def up
    add_column :preview_panel_versions, :file_count, :integer unless column_exists?(:preview_panel_versions, :file_count)
    add_column :preview_panel_versions, :entry_viewer_kind, :string unless column_exists?(:preview_panel_versions, :entry_viewer_kind)

    Version.reset_column_information
    attachment_counts = select_all(<<~SQL.squish).to_h { |row| [ row.fetch("record_id").to_i, row.fetch("attachment_count").to_i ] }
      SELECT record_id, COUNT(*) AS attachment_count
      FROM active_storage_attachments
      WHERE record_type = 'PreviewPanelVersion' AND name = 'files'
      GROUP BY record_id
    SQL

    Version.find_each do |version|
      version.update_columns(
        file_count: attachment_counts.fetch(version.id, 0),
        entry_viewer_kind: viewer_kind(version.entry_file)
      )
    end

    change_column_default :preview_panel_versions, :file_count, nil
    change_column_default :preview_panel_versions, :entry_viewer_kind, nil
    change_column_null :preview_panel_versions, :file_count, false
    change_column_null :preview_panel_versions, :entry_viewer_kind, false
  end

  def down
    remove_column :preview_panel_versions, :entry_viewer_kind if column_exists?(:preview_panel_versions, :entry_viewer_kind)
    remove_column :preview_panel_versions, :file_count if column_exists?(:preview_panel_versions, :file_count)
  end

  private

  def viewer_kind(path)
    extension = File.extname(path.to_s).downcase
    content_type = Marcel::MimeType.for(name: path.to_s)

    return "html" if %w[.html .htm].include?(extension) || content_type == "text/html"
    return "markdown" if %w[.md .markdown .mdown .mkdn].include?(extension) || content_type == "text/markdown"
    return "pdf" if content_type == "application/pdf"
    return "image" if %w[image/svg+xml image/png image/jpeg image/webp image/gif].include?(content_type)

    "unsupported"
  end
end
