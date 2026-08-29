require "mcp"

module PreviewTools
  class ShowPreviewTool < MCP::Tool
    extend ToolSupport

    tool_name "show_preview"

    description "Publish a panel's scratch directory to a live preview tab in the operator's " \
                "chat sidebar. Without panel_id, opens a new empty panel and returns its id -- " \
                "write files into that panel's scratch directory with write_preview_file, then call " \
                "show_preview again with the same panel_id to publish them. With panel_id, " \
                "walks the panel's current scratch directory and replaces the panel's published " \
                "files with it (deleted scratch files stop being served), so you can call this " \
                "repeatedly to iterate in place. The panel root serves entry_file, defaulting to index.html."

    input_schema(
      type: "object",
      required: %w[title],
      properties: {
        panel_id:   { type: "string", description: "Existing open panel id to update in place. Omit to open a new panel." },
        title:      { type: "string", description: "Panel title shown in the chat sidebar tab." },
        entry_file: { type: "string", description: "Relative path of the file that must exist before publishing. Defaults to index.html." }
      }
    )

    class << self
      def call(chat_session:, server_context: nil, panel_id: nil, title: nil, entry_file: nil)
        return error_response("title is required") if title.blank?

        if panel_id.blank?
          panel = PreviewPanel::Service.open!(chat_session: chat_session, title: title, files: {})
          return ok_response(panel_payload(
            panel,
            note: "Opened an empty preview panel. Write files into its scratch directory with " \
                  "write_preview_file (panel_id: #{panel.id}), then call show_preview again with the " \
                  "same panel_id to publish them."
          ))
        end

        panel = find_open_panel(chat_session, panel_id)
        return panel_not_found_response(panel_id) unless panel

        scratch = ScratchDirectory.new(chat_session, panel.id)
        files = scratch.files
        return error_response("No files found in panel #{panel.id}'s scratch directory yet -- use write_preview_file first.") if files.empty?

        resolved_entry_file = entry_file.presence || PreviewPanel::DEFAULT_ENTRY_FILENAME
        unless scratch.exist?(resolved_entry_file)
          return error_response("entry_file #{resolved_entry_file.inspect} was not found among the scratch files: #{files.keys.sort.join(', ')}.")
        end

        updated = PreviewPanel::Service.new(panel).update!(
          files: files.transform_values { |path| File.binread(path) },
          entry_file: resolved_entry_file
        )
        ok_response(panel_payload(updated))
      end
    end
  end
end
