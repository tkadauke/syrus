require "mcp"

module PreviewTools
  # Planning-mode-only chat MCP tools. Planning mode has no Write/Edit tools
  # at all (Prompts::ChatSystem) so an agent that wants to build an HTML/CSS/JS
  # mockup or interactive widget page needs a narrow, jailed alternative:
  # write/edit that can only touch a PreviewPanel's own scratch directory,
  # plus show_preview/close_preview to publish that directory to the panel
  # the operator sees in the chat sidebar.
  #
  # Both "quick interactive widget" and "freeform mockup" go through the
  # same show_preview call -- the only difference is what the agent wrote
  # into the scratch directory (a CDN <script>/<link> tag vs. hand-authored
  # layout).
  class ChatToolSet
    WRITE_FILE    = "write_preview_file"
    EDIT_FILE     = "edit_preview_file"
    SHOW_PREVIEW  = "show_preview"
    CLOSE_PREVIEW = "close_preview"

    def self.available_for?(chat_session, tier:)
      !chat_session.coding? && !chat_session.local? && %i[essential deferred].include?(tier.to_sym)
    end

    def self.tool_definitions(tier:)
      [
        {
          name: WRITE_FILE,
          description: "Write (create or overwrite) a file inside a preview panel's private scratch " \
                        "directory. Scoped to that panel only -- it cannot touch the attached " \
                        "repository checkout or any other panel's files. panel_id must be an open " \
                        "panel id returned by #{SHOW_PREVIEW}.",
          input_schema: {
            type: "object",
            required: %w[panel_id path content],
            properties: {
              panel_id: { type: "string", description: "Open preview panel id, from #{SHOW_PREVIEW}." },
              path:     { type: "string", description: "File path relative to the panel's scratch directory, e.g. \"index.html\" or \"css/app.css\"." },
              content:  { type: "string", description: "Full file content." }
            }
          }
        },
        {
          name: EDIT_FILE,
          description: "Replace old_string with new_string in a file inside a preview panel's " \
                        "scratch directory. old_string must appear exactly once in the file unless " \
                        "replace_all is set -- same contract as a normal Edit tool.",
          input_schema: {
            type: "object",
            required: %w[panel_id path old_string new_string],
            properties: {
              panel_id:    { type: "string", description: "Open preview panel id, from #{SHOW_PREVIEW}." },
              path:        { type: "string", description: "File path relative to the panel's scratch directory." },
              old_string:  { type: "string", description: "Exact text to replace." },
              new_string:  { type: "string", description: "Replacement text." },
              replace_all: { type: "boolean", description: "Replace every occurrence instead of requiring old_string to be unique. Defaults to false." }
            }
          }
        },
        {
          name: SHOW_PREVIEW,
          description: "Publish a panel's scratch directory to a live preview tab in the operator's " \
                        "chat sidebar. Without panel_id, opens a new empty panel and returns its id -- " \
                        "write files into that panel's scratch directory with #{WRITE_FILE}, then call " \
                        "#{SHOW_PREVIEW} again with the same panel_id to publish them. With panel_id, " \
                        "walks the panel's current scratch directory and replaces the panel's published " \
                        "files with it (deleted scratch files stop being served), so you can call this " \
                        "repeatedly to iterate in place. The panel always serves \"index.html\" for its " \
                        "root URL, regardless of entry_file, so name your landing page index.html.",
          input_schema: {
            type: "object",
            required: %w[title],
            properties: {
              panel_id:   { type: "string", description: "Existing open panel id to update in place. Omit to open a new panel." },
              title:      { type: "string", description: "Panel title shown in the chat sidebar tab." },
              entry_file: { type: "string", description: "Relative path of the file that must exist before publishing. Defaults to index.html." }
            }
          }
        },
        {
          name: CLOSE_PREVIEW,
          description: "Close an open preview panel, removing its tab from the chat sidebar.",
          input_schema: {
            type: "object",
            required: %w[panel_id],
            properties: {
              panel_id: { type: "string", description: "Open preview panel id to close." }
            }
          }
        }
      ]
    end

    def handle(tool_name, params, server_context)
      chat_session = server_context && server_context[:chat_session]
      return error_response("No chat session available in this context.") unless chat_session

      params = normalize_params(params)

      case tool_name.to_s
      when WRITE_FILE    then handle_write(chat_session, params)
      when EDIT_FILE     then handle_edit(chat_session, params)
      when SHOW_PREVIEW  then handle_show_preview(chat_session, params)
      when CLOSE_PREVIEW then handle_close_preview(chat_session, params)
      else
        error_response("Unknown preview tool: #{tool_name.inspect}")
      end
    rescue ScratchDirectory::InvalidPath => e
      error_response(e.message)
    rescue StandardError => e
      Rails.logger.error("[PreviewTools::ChatToolSet] #{e.class}: #{e.message}")
      error_response("#{e.class}: #{e.message}")
    end

    private

    def handle_write(chat_session, params)
      panel = find_open_panel(chat_session, params[:panel_id])
      return panel_not_found_response(params[:panel_id]) unless panel
      return error_response("path is required") if params[:path].blank?

      ScratchDirectory.new(chat_session, panel.id).write(params[:path], params[:content])
      ok_response(panel_id: panel.id, path: params[:path])
    end

    def handle_edit(chat_session, params)
      panel = find_open_panel(chat_session, params[:panel_id])
      return panel_not_found_response(params[:panel_id]) unless panel
      return error_response("path is required") if params[:path].blank?

      replacements = ScratchDirectory.new(chat_session, panel.id).edit(
        params[:path],
        params[:old_string].to_s,
        params[:new_string].to_s,
        replace_all: truthy?(params[:replace_all])
      )
      ok_response(panel_id: panel.id, path: params[:path], replacements: replacements)
    end

    def handle_show_preview(chat_session, params)
      return error_response("title is required") if params[:title].blank?

      if params[:panel_id].blank?
        panel = PreviewPanel::Service.open!(chat_session: chat_session, title: params[:title], files: {})
        return ok_response(panel_payload(
          panel,
          note: "Opened an empty preview panel. Write files into its scratch directory with " \
                "#{WRITE_FILE} (panel_id: #{panel.id}), then call #{SHOW_PREVIEW} again with the " \
                "same panel_id to publish them."
        ))
      end

      panel = find_open_panel(chat_session, params[:panel_id])
      return panel_not_found_response(params[:panel_id]) unless panel

      scratch = ScratchDirectory.new(chat_session, panel.id)
      files = scratch.files
      return error_response("No files found in panel #{panel.id}'s scratch directory yet -- use #{WRITE_FILE} first.") if files.empty?

      entry_file = params[:entry_file].presence || PreviewPanel::DEFAULT_ENTRY_FILENAME
      unless scratch.exist?(entry_file)
        return error_response("entry_file #{entry_file.inspect} was not found among the scratch files: #{files.keys.sort.join(', ')}.")
      end

      updated = PreviewPanel::Service.new(panel).update!(files: files.transform_values { |path| File.binread(path) })
      ok_response(panel_payload(updated))
    end

    def handle_close_preview(chat_session, params)
      panel = chat_session.preview_panels.find_by(id: params[:panel_id])
      return panel_not_found_response(params[:panel_id]) unless panel

      closed = PreviewPanel::Service.new(panel).close!
      ok_response(panel_payload(closed))
    end

    def find_open_panel(chat_session, panel_id)
      return nil if panel_id.blank?

      chat_session.preview_panels.find_by(id: panel_id, state: "open")
    end

    def panel_payload(panel, note: nil)
      base_domain = ENV.fetch("SYRUS_PREVIEW_BASE_DOMAIN", "lvh.me")
      {
        panel_id: panel.id,
        title: panel.title,
        state: panel.state,
        url: panel.preview_url(base_domain),
        file_count: panel.files.size,
        note: note
      }.compact
    end

    def panel_not_found_response(panel_id)
      error_response("No open preview panel #{panel_id.inspect} for this chat.")
    end

    def normalize_params(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value) ? true : false
    end

    def ok_response(data)
      MCP::Tool::Response.new([ { type: "text", text: JSON.generate(data) } ])
    end

    def error_response(message)
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{message}" } ], error: true)
    end
  end
end
