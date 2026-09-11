require "mcp"

module Mockups
  class EditPreviewFileTool < MCP::Tool
    extend ToolSupport

    tool_name "edit_preview_file"

    description "Edit a file inside a preview panel's scratch directory for UI mockups, " \
                "HTML mockups, HTML previews, prototypes, open-preview requests, and " \
                "screenshot-driven interface redesigns. Use after show_preview opens a panel; " \
                "then call show_preview again with the same panel_id to publish the visible " \
                "preview. Do not use local HTTP servers, local file paths, workspace-only HTML " \
                "files, or imagegen as the primary path for HTML/UI mockups. Replace old_string " \
                "with new_string. old_string must appear exactly once in the file unless " \
                "replace_all is set -- same contract as a normal Edit tool."

    input_schema(
      type: "object",
      required: %w[panel_id path old_string new_string],
      properties: {
        panel_id:    { type: "string", description: "Open preview panel id, from show_preview." },
        path:        { type: "string", description: "File path relative to the panel's scratch directory." },
        old_string:  { type: "string", description: "Exact text to replace." },
        new_string:  { type: "string", description: "Replacement text." },
        replace_all: { type: "boolean", description: "Replace every occurrence instead of requiring old_string to be unique. Defaults to false." }
      }
    )

    class << self
      def call(chat_session:, server_context: nil, panel_id: nil, path: nil, old_string: nil, new_string: nil, replace_all: nil)
        panel = find_open_panel(chat_session, panel_id)
        return panel_not_found_response(panel_id) unless panel
        return error_response("path is required") if path.blank?

        replacements = ScratchDirectory.new(chat_session, panel.id).edit(
          path,
          old_string.to_s,
          new_string.to_s,
          replace_all: truthy?(replace_all)
        )
        ok_response(panel_id: panel.id, path: path, replacements: replacements)
      end
    end
  end
end
