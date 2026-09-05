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
      chat_session.preview_panels.where(state: "open").includes(preview_panel_versions: { files_attachments: :blob }).order(:created_at, :id).map do |panel|
        base = "/api/v1/app/chats/#{chat_session.id}/preview_panels/#{panel.id}"
        # Core owns the shape; chat adds the two mutations only it offers.
        PreviewPanel::Payload.new(panel, base_path: base, scheme: scheme).as_json.merge(
          app_close_path: base,
          app_visibility_path: base
        )
      end
    end
  end
end
