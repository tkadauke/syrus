require "mcp"

module Mockups
  class WritePreviewFileTool < MCP::Tool
    extend ToolSupport

    tool_name "write_preview_file"

    description "Write (create or overwrite) a file inside a preview panel's private scratch " \
                "directory for UI mockups, HTML mockups, HTML previews, prototypes, open-preview " \
                "requests, and screenshot-driven interface redesigns. Canonical sequence: call " \
                "show_preview without panel_id to open a panel, write index.html and assets with " \
                "write_preview_file, then call show_preview again with the same panel_id to publish. " \
                "Scoped to that panel only -- it cannot touch the attached repository checkout or " \
                "any other panel's files. Do not use local HTTP servers, local file paths, or " \
                "workspace-only HTML files as the primary deliverable when preview-panel tools are " \
                "available. Do not use imagegen for HTML/UI mockups unless the user explicitly asks " \
                "for a bitmap/raster image. panel_id must be an open panel id returned by show_preview."

    input_schema(
      type: "object",
      required: %w[panel_id path content],
      properties: {
        panel_id: { type: "string", description: "Open preview panel id, from show_preview." },
        path:     { type: "string", description: "File path relative to the panel's scratch directory, e.g. \"index.html\" or \"css/app.css\"." },
        content:  { type: "string", description: "Full file content." }
      }
    )

    class << self
      def call(chat_session:, server_context: nil, panel_id: nil, path: nil, content: nil)
        panel = find_open_panel(chat_session, panel_id)
        return panel_not_found_response(panel_id) unless panel
        return error_response("path is required") if path.blank?

        ScratchDirectory.new(chat_session, panel.id).write(path, content)
        ok_response(panel_id: panel.id, path: path)
      end
    end
  end
end
