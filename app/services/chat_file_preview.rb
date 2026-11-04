class ChatFilePreview
  Result = Data.define(:content_type, :bytes, :viewer_kind)

  MARKDOWN_EXTENSIONS = %w[.md .markdown .mdown .mkd].freeze

  SIGNATURES = [
    [ "image/png", ->(bytes) { bytes.start_with?("\x89PNG\r\n\x1A\n".b) } ],
    [ "image/jpeg", ->(bytes) { bytes.start_with?("\xFF\xD8\xFF".b) } ],
    [ "image/gif", ->(bytes) { bytes.start_with?("GIF87a".b) || bytes.start_with?("GIF89a".b) } ],
    [ "image/webp", ->(bytes) { bytes.start_with?("RIFF".b) && bytes.byteslice(8, 4) == "WEBP".b } ],
    [ "application/pdf", ->(bytes) { bytes.start_with?("%PDF-".b) } ],
    [ "image/svg+xml", ->(bytes) { svg?(bytes) } ]
  ].freeze
  EXTENSIONS = {
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".svg" => "image/svg+xml",
    ".pdf" => "application/pdf"
  }.freeze

  class << self
    def inspect(bytes, path:)
      allowed_content_type = EXTENSIONS[File.extname(path).downcase]
      return unless allowed_content_type

      match = SIGNATURES.find { |_content_type, predicate| predicate.call(bytes) }
      return unless match&.first == allowed_content_type

      Result.new(
        content_type: match.first,
        bytes: bytes,
        viewer_kind: match.first == "application/pdf" ? "pdf" : "image"
      )
    end

    def viewer_kind(bytes, path:, binary:)
      return inspect(bytes, path:)&.viewer_kind if EXTENSIONS.key?(File.extname(path).downcase)
      return if binary

      MARKDOWN_EXTENSIONS.include?(File.extname(path).downcase) ? "markdown" : nil
    end

    private

    def svg?(bytes)
      return false if bytes.include?("\x00".b)

      prefix = bytes.byteslice(0, 4096).to_s.force_encoding(Encoding::UTF_8)
      prefix.valid_encoding? && prefix.match?(/\A\s*(?:<\?xml[^>]*>\s*)?(?:<!--.*?-->\s*)*<svg(?:\s|>)/mi)
    end
  end
end
