require "mcp"

module Mockups
  # Read-only inspection of a preview panel's preserved versions. Never touches
  # the scratch directory or the panel's current version, and works for open
  # and closed panels alike (any panel of the current chat).
  class InspectPreviewVersionsTool < MCP::Tool
    extend ToolSupport

    MAX_TEXT_BYTES = 64 * 1024
    TEXT_CONTENT_TYPES = %w[application/json application/javascript application/xml image/svg+xml].freeze
    TEXT_EXTENSIONS = %w[.html .htm .css .js .mjs .json .md .markdown .svg .txt .xml .csv .ts .tsx .jsx .yml .yaml].freeze

    tool_name "inspect_preview_versions"

    description "Read-only: inspect old, previous, or historical versions of a preview panel (mockup). " \
                "Use this before modifying an existing mockup whose earlier version is referenced, " \
                "instead of reconstructing that version from memory. Without path, lists every preserved " \
                "version (version_id, created_at, entry_file, stored file paths, sizes) and the current " \
                "version_id. With path, returns that text file (HTML, CSS, JavaScript, JSON, Markdown, SVG) " \
                "from version_id, defaulting to the current version; binary files return metadata only and " \
                "long text is truncated with truncated/total_bytes metadata. Works for open and closed " \
                "panels of this chat. Does not publish, restore, or change the scratch directory or the " \
                "panel's current version."

    input_schema(
      type: "object",
      required: %w[panel_id],
      properties: {
        panel_id:   { type: "string", description: "Preview panel id (open or closed) belonging to this chat." },
        version_id: { type: "string", description: "Version id to read. Defaults to the current version." },
        path:       { type: "string", description: "Relative file path to read, e.g. index.html. Omit to list versions and files." }
      }
    )

    class << self
      def call(chat_session:, server_context: nil, panel_id: nil, version_id: nil, path: nil)
        panel = panel_id.present? ? chat_session.preview_panels.find_by(id: panel_id) : nil
        return error_response("No preview panel #{panel_id.inspect} for this chat.") unless panel

        versions = panel.preview_panel_versions.includes(files_attachments: :blob).to_a
        current = panel.current_version
        if path.blank? && version_id.blank?
          return ok_response(panel_id: panel.id, state: panel.state, current_version_id: current&.id,
                             versions: versions.map { |version| version_summary(version) })
        end

        version = version_id.present? ? versions.find { |candidate| candidate.id.to_s == version_id.to_s } : current
        if version.nil?
          return error_response("Version #{version_id.inspect} does not belong to preview panel #{panel.id}.") if version_id.present?

          return error_response("Preview panel #{panel.id} has no published versions.")
        end
        return ok_response(panel_id: panel.id, current_version_id: current&.id, version: version_summary(version)) if path.blank?

        read_file(panel, version, path)
      end

      private

      def version_summary(version)
        {
          version_id: version.id,
          created_at: version.created_at&.iso8601,
          entry_file: version.entry_file,
          files: version.files.map { |file| file_metadata(file) }.sort_by { |file| file[:path] }
        }
      end

      def file_metadata(attachment)
        { path: attachment.blob.metadata["relative_path"], content_type: attachment.blob.content_type, byte_size: attachment.blob.byte_size }
      end

      def read_file(panel, version, path)
        attachment = version.file_for(path)
        unless attachment
          available = version.files.map { |file| file.blob.metadata["relative_path"] }.compact.sort
          return error_response("Path #{path.inspect} not found in version #{version.id} of preview panel #{panel.id}. Available: #{available.join(', ')}.")
        end

        meta = file_metadata(attachment).merge(panel_id: panel.id, version_id: version.id)
        content = attachment.blob.download
        return ok_response(meta.merge(binary: true, note: "Binary file; contents not included.")) unless text?(meta, content)

        truncated = content.bytesize > MAX_TEXT_BYTES
        text = content.byteslice(0, MAX_TEXT_BYTES).force_encoding(Encoding::UTF_8).scrub("")
        ok_response(meta.merge(binary: false, truncated: truncated, returned_bytes: text.bytesize, total_bytes: content.bytesize, content: text))
      end

      def text?(meta, content)
        type = meta[:content_type].to_s
        known = type.start_with?("text/") || TEXT_CONTENT_TYPES.include?(type) || TEXT_EXTENSIONS.include?(File.extname(meta[:path].to_s).downcase)
        known && !content.include?("\0")
      end
    end
  end
end
