class PreviewPanel::EntryMetadata
  MARKDOWN_EXTENSIONS = %w[.md .markdown .mdown .mkdn].freeze
  IMAGE_CONTENT_TYPES = %w[image/svg+xml image/png image/jpeg image/webp image/gif].freeze

  def self.content_type(path)
    Marcel::MimeType.for(name: path.to_s)
  end

  def self.markdown_path?(path)
    MARKDOWN_EXTENSIONS.include?(File.extname(path.to_s).downcase)
  end

  # The viewer the panel should render this entry with.
  #
  # Core's kinds are checked first: a plugin extends the set, it does not
  # reinterpret a file core already knows how to show. Anything neither core
  # nor a plugin claims falls through to "unsupported", which the frontend
  # renders as source text.
  def self.viewer_kind(path)
    content_type = content_type(path)
    extension = File.extname(path.to_s).downcase

    return "html" if %w[.html .htm].include?(extension) || content_type == "text/html"
    return "markdown" if markdown_path?(path) || content_type == "text/markdown"
    return "pdf" if content_type == "application/pdf"
    return "image" if IMAGE_CONTENT_TYPES.include?(content_type)

    plugin_viewer_kind(extension, content_type) || "unsupported"
  end

  # Never lets a misbehaving plugin break the panel: a provider that raises or
  # returns nonsense is skipped, and the entry falls back to source text.
  def self.plugin_viewer_kind(extension, content_type)
    Syrus::PluginRegistry.providers_for(:preview_panel_viewer).each do |provider|
      Array(provider.viewer_kinds).each do |entry|
        entry = entry.to_h.symbolize_keys
        kind = entry[:kind].to_s
        next if kind.empty?

        return kind if Array(entry[:extensions]).map(&:to_s).include?(extension)
        return kind if Array(entry[:content_types]).map(&:to_s).include?(content_type)
      end
    rescue StandardError => e
      Rails.logger.warn("[PreviewPanel] viewer kinds from #{provider} failed: #{e.class}: #{e.message}")
      next
    end

    nil
  end
  private_class_method :plugin_viewer_kind
end
