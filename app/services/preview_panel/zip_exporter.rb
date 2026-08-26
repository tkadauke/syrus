# Builds a zip archive of a PreviewPanelVersion's attached files, preserving
# their relative_path directory structure, so an operator can download a
# panel snapshot the same way they can view it in the sandboxed iframe.
class PreviewPanel::ZipExporter
  def initialize(version)
    @version = version
  end

  # Returns the zip archive as a binary String, suitable for send_data.
  def call
    buffer = Zip::OutputStream.write_buffer do |zip|
      version.files.each do |attachment|
        relative_path = attachment.blob.metadata["relative_path"].presence || attachment.filename.to_s
        zip.put_next_entry(relative_path)
        zip.write(attachment.download)
      end
    end
    buffer.string
  end

  private

  attr_reader :version
end
