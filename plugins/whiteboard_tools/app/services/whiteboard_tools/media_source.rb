module WhiteboardTools
  # The "snapshot:<id>" media kind. Core used to carry this as a branch in
  # ChatMediaAttacher, ChatProposal, submit_chat_feedback, list_chat_media,
  # and ChatMediaRef's format regex.
  module MediaSource
    include Syrus::Plugin::ChatMediaSource

    def self.chat_media_kind = "snapshot"

    def self.chat_media_exists?(chat_session:, id:)
      WhiteboardSnapshot.where(chat_session_id: chat_session.id).exists?(id)
    end

    def self.attach_chat_media(chat_session:, job:, ref:, id:)
      snapshot = WhiteboardSnapshot.where(chat_session_id: chat_session.id).find_by(id: id)
      return nil unless snapshot

      job.job_attachments.create!(
        kind: "pending_snapshot",
        title: snapshot.name.presence || "Whiteboard Snapshot",
        content_cache: snapshot.scene_json.to_json,
        source_url: ref
      )
    end

    def self.list_chat_media(chat_session:)
      WhiteboardSnapshot.where(chat_session_id: chat_session.id).limit(10).map do |snapshot|
        {
          id: "snapshot:#{snapshot.id}",
          kind: "snapshot",
          name: snapshot.name,
          element_count: snapshot.element_count,
          created_at: snapshot.created_at&.iso8601
        }
      end
    end

    # The media panel's whiteboard section: every snapshot, plus whether the
    # live canvas has edits no snapshot captured yet.
    def self.chat_media_panel(chat_session:)
      board = Whiteboard.find_by(chat_session_id: chat_session.id)
      elements = board ? Array(board.scene_json&.dig("elements")).reject { |el| el["isDeleted"] } : []
      snapshots = WhiteboardSnapshot.where(chat_session_id: chat_session.id).order(created_at: :desc)
      latest_manual = snapshots.find { |snapshot| snapshot.snapshot_kind == "manual" }
      last_edited = board&.last_edited_at || board&.created_at

      {
        snapshots: snapshots.map do |snapshot|
          {
            id: snapshot.id,
            name: snapshot.name,
            snapshot_kind: snapshot.snapshot_kind,
            element_count: snapshot.element_count,
            created_at: snapshot.created_at.iso8601
          }
        end,
        whiteboard_has_unsaved_content: elements.any? &&
          (latest_manual.nil? || (last_edited && last_edited > latest_manual.created_at))
      }
    end

    # How full the canvas is right now, reported beside the snapshot list so
    # the agent can tell an empty board from one worth saving.
    def self.chat_media_context(chat_session:)
      board = Whiteboard.find_by(chat_session_id: chat_session.id)
      { whiteboard_element_count: board&.elements&.size || 0 }
    end
  end
end
