module WhiteboardTools
  class Snapshot < ApplicationRecord
    self.table_name = "whiteboard_tools_snapshots"

    SNAPSHOT_KINDS = %w[manual auto_clear auto_before_load].freeze
    KIND_PREFIXES = { "auto_clear" => "Before clear", "auto_before_load" => "Before load" }.freeze

    belongs_to :chat_session

    # Replaces `ChatSession has_many :whiteboard_snapshots`.
    def self.for(chat_session) = where(chat_session_id: chat_session.id)

    default_scope -> { order(created_at: :desc) }

    validates :scene_json, :snapshot_kind, :element_count, presence: true
    validates :snapshot_kind, inclusion: { in: SNAPSHOT_KINDS }

    def self.create_from_scene!(chat_session:, scene:, kind:, name: nil)
      normalized_scene = WhiteboardTools::Board.normalize_scene!(scene)
      snapshot = create!(
        chat_session: chat_session,
        name: name || default_name_for(kind),
        scene_json: normalized_scene,
        snapshot_kind: kind,
        element_count: normalized_scene.fetch("elements").size
      )
      snapshot.broadcast_created
      snapshot
    end

    def broadcast_created
      AppEvents.broadcast(
        user: chat_session.user,
        type: "updated",
        resource: "chat",
        id: chat_session_id,
        changed: [ "whiteboard_snapshots" ],
        payload: { action: "whiteboard_snapshots_changed" }
      )
    end

    def self.default_name_for(kind)
      prefix = KIND_PREFIXES.fetch(kind, "Snapshot")
      "#{prefix} - #{Time.current.strftime('%b %-d %H:%M')}"
    end
  end
end
