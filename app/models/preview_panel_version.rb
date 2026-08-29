class PreviewPanelVersion < ApplicationRecord
  belongs_to :preview_panel
  has_many_attached :files

  default_scope -> { order(created_at: :desc) }

  validates :entry_file, presence: true

  # Mirrors PreviewPanel#file_for: looks up an attached file by its stored
  # relative path, going through blob metadata since ActiveStorage sanitizes
  # "/" out of filenames.
  def file_for(relative_path)
    path = relative_path.to_s.delete_prefix("/").presence || entry_file.presence || PreviewPanel::DEFAULT_ENTRY_FILENAME
    files.find { |attachment| attachment.blob.metadata["relative_path"] == path }
  end

  def entry_attachment = file_for(entry_file)
  def entry_content_type = PreviewPanel::EntryMetadata.content_type(entry_file)
  def entry_viewer_kind = PreviewPanel::EntryMetadata.viewer_kind(entry_file)
end
