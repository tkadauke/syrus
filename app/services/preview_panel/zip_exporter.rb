# Builds a zip archive of a PreviewPanelVersion's attached files, preserving
# their relative_path directory structure, so an operator can download a
# panel snapshot the same way they can view it in the sandboxed iframe.
class PreviewPanel::ZipExporter
  def initialize(version)
    @version = version
  end

  # Returns the zip archive as a binary String, suitable for send_data.
  def call
    Rails.cache.fetch([ "preview-panel-export", version.id ]) { build_zip }
  end

  private

  def build_zip
    buffer = Zip::OutputStream.write_buffer do |zip|
      version.files.each do |attachment|
        zip.put_next_entry(attachment.blob.metadata["relative_path"])
        zip.write(attachment.download)
      end
    end
    buffer.string
  end

  attr_reader :version
end
