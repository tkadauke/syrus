class PreviewPanelVersion < ApplicationRecord
  belongs_to :preview_panel
  has_many_attached :files

  default_scope -> { order(created_at: :desc) }

  # Mirrors PreviewPanel#file_for: looks up an attached file by its stored
  # relative path, going through blob metadata since ActiveStorage sanitizes
  # "/" out of filenames.
  def file_for(relative_path)
    path = relative_path.to_s.delete_prefix("/").presence || PreviewPanel::DEFAULT_ENTRY_FILENAME
    files.find { |attachment| attachment.blob.metadata["relative_path"] == path }
  end
end
