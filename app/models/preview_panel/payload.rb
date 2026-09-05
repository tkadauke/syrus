class PreviewPanel
  # One serialization of a panel, for whoever is showing it.
  #
  # This lived in the chat payload contributor and hardcoded chat-scoped URLs,
  # so a panel could only be rendered inside the chat it was opened in. The
  # shape is the same wherever it is shown; only the base path differs, so that
  # is the parameter.
  class Payload
    def initialize(panel, base_path: nil, scheme: "http", base_domain: nil)
      @panel = panel
      @base_path = base_path.presence || "/api/v1/app/preview_panels/#{panel.id}"
      @scheme = scheme
      @base_domain = base_domain.presence || ENV.fetch("SYRUS_PREVIEW_BASE_DOMAIN", "lvh.me")
    end

    def as_json(*)
      versions = @panel.preview_panel_versions
      current = versions.first

      {
        id: @panel.id,
        title: @panel.title,
        state: @panel.state,
        visibility: @panel.visibility,
        file_count: current&.files&.size || 0,
        url: @panel.preview_url(@base_domain, scheme: @scheme),
        app_export_path: "#{@base_path}/export",
        app_file_base_path: "#{@base_path}/files",
        app_token_path: "#{@base_path}/token",
        current_version_id: current&.id,
        entry_path: current&.entry_file || DEFAULT_ENTRY_FILENAME,
        entry_content_type: current&.entry_content_type || EntryMetadata.content_type(DEFAULT_ENTRY_FILENAME),
        entry_viewer_kind: current&.entry_viewer_kind || "html",
        updated_at: @panel.updated_at&.iso8601,
        versions: versions.map { |version| self.class.version_json(version) }
      }
    end

    def self.version_json(version)
      {
        id: version.id,
        created_at: version.created_at.iso8601,
        entry_path: version.entry_file,
        entry_content_type: version.entry_content_type,
        entry_viewer_kind: version.entry_viewer_kind
      }
    end
  end
end
