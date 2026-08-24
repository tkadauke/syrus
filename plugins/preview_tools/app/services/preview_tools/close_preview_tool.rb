require "mcp"

module PreviewTools
  class ClosePreviewTool < MCP::Tool
    extend ToolSupport

    tool_name "close_preview"

    description "Close an open preview panel, removing its tab from the chat sidebar."

    input_schema(
      type: "object",
      required: %w[panel_id],
      properties: {
        panel_id: { type: "string", description: "Open preview panel id to close." }
      }
    )

    class << self
      def call(chat_session:, server_context: nil, panel_id: nil)
        panel = chat_session.preview_panels.find_by(id: panel_id)
        return panel_not_found_response(panel_id) unless panel

        closed = PreviewPanel::Service.new(panel).close!
        ok_response(panel_payload(closed))
      end
    end
  end
end
