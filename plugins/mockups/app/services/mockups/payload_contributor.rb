module Mockups
  # The chat payload's `preview_panels` key. Core used to build this inline in
  # ChatSerialization, which meant it knew PreviewPanel's URL scheme, entry
  # metadata, and version serialization.
  module PayloadContributor
    include Syrus::Plugin::ChatPayloadContributor

    def self.chat_payload(chat_session:, context:)
      scheme = context[:ssl] ? "https" : "http"
      { preview_panels: panels_json(chat_session, scheme: scheme) }
    end

    def self.panels_json(chat_session, scheme:)
      base_domain = ENV.fetch("SYRUS_PREVIEW_BASE_DOMAIN", "lvh.me")
      chat_session.preview_panels.where(state: "open").includes(preview_panel_versions: { files_attachments: :blob }).order(:created_at, :id).map do |panel|
        versions = panel.preview_panel_versions
        current = versions.first
        {
          id: panel.id,
          title: panel.title,
          file_count: current&.files&.size || 0,
          url: panel.preview_url(base_domain, scheme: scheme),
          visibility: panel.visibility,
          app_close_path: "/api/v1/app/chats/#{chat_session.id}/preview_panels/#{panel.id}",
          app_visibility_path: "/api/v1/app/chats/#{chat_session.id}/preview_panels/#{panel.id}",
          app_export_path: "/api/v1/app/chats/#{chat_session.id}/preview_panels/#{panel.id}/export",
          app_file_base_path: "/api/v1/app/chats/#{chat_session.id}/preview_panels/#{panel.id}/files",
          app_token_path: "/api/v1/app/chats/#{chat_session.id}/preview_panels/#{panel.id}/token",
          current_version_id: current&.id,
          entry_path: current&.entry_file || PreviewPanel::DEFAULT_ENTRY_FILENAME,
          entry_content_type: current&.entry_content_type || PreviewPanel::EntryMetadata.content_type(PreviewPanel::DEFAULT_ENTRY_FILENAME),
          entry_viewer_kind: current&.entry_viewer_kind || "html",
          versions: versions.map { |version| version_json(version) }
        }
      end
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
