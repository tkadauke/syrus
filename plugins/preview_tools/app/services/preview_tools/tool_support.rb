module PreviewTools
  # Shared response/panel-lookup helpers for the individual preview tool
  # classes (see ChatToolSet). `extend`ed into each tool class so they're
  # available as class methods from `.call`.
  module ToolSupport
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
        file_count: panel.current_version&.files&.size || 0,
        version_id: panel.current_version&.id,
        note: note
      }.compact
    end

    def panel_not_found_response(panel_id)
      error_response("No open preview panel #{panel_id.inspect} for this chat.")
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
