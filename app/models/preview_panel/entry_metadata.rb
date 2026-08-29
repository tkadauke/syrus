class PreviewPanel::EntryMetadata
  MARKDOWN_EXTENSIONS = %w[.md .markdown .mdown .mkdn].freeze
  IMAGE_CONTENT_TYPES = %w[image/svg+xml image/png image/jpeg image/webp image/gif].freeze

  def self.content_type(path)
    Marcel::MimeType.for(name: path.to_s)
  end

  def self.markdown_path?(path)
    MARKDOWN_EXTENSIONS.include?(File.extname(path.to_s).downcase)
  end

  def self.viewer_kind(path)
    content_type = content_type(path)
    extension = File.extname(path.to_s).downcase

    return "html" if %w[.html .htm].include?(extension) || content_type == "text/html"
    return "markdown" if markdown_path?(path) || content_type == "text/markdown"
    return "pdf" if content_type == "application/pdf"
    return "image" if IMAGE_CONTENT_TYPES.include?(content_type)

    "unsupported"
  end
end
