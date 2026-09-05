module Whiteboard
  # The chat payload's `whiteboard` key, its path, and its snapshot count.
  # Core used to build all three inline in ChatSerialization and the chats
  # controller's counts query.
  module PayloadContributor
    include Syrus::Plugin::ChatPayloadContributor

    def self.chat_payload(chat_session:, context:)
      # The full scene is large, so it ships only when asked for.
      include_scene = context.dig(:params, :include_whiteboard).present?
      scene = scene_for(chat_session, include_scene: include_scene)

      {
        whiteboard: {
          version: scene.fetch("version"),
          elements: scene.fetch("elements"),
          appState: scene.fetch("appState"),
          files: scene.fetch("files"),
          loaded: scene.fetch("loaded")
        }
      }
    end

    def self.chat_payload_paths(chat_session:)
      { app_whiteboard_path: "/api/v1/app/chats/#{chat_session.id}/whiteboard" }
    end

    def self.chat_payload_counts(chat_session:)
      { whiteboard_snapshot_count: Whiteboard::Snapshot.where(chat_session_id: chat_session.id).count }
    end

    def self.scene_for(chat_session, include_scene:)
      return Whiteboard::Board.default_state.merge("loaded" => false) unless include_scene

      row = payload_scope(chat_session.id).pick(:scene_json, :version)
      return Whiteboard::Board.default_state.merge("loaded" => true) unless row

      scene_json, version = row
      Whiteboard::Board.normalize_scene!(scene_json).merge("version" => version, "loaded" => true)
    end

    # MySQL picks a worse plan without the hint on chats with many rows.
    def self.payload_scope(chat_session_id)
      scope = Whiteboard::Board.where(chat_session_id: chat_session_id)
      return scope unless ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")

      scope.from(Arel.sql("#{Whiteboard.quoted_table_name} FORCE INDEX (index_whiteboard_boards_on_chat_session_id)"))
    end
  end
end
