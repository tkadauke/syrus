module Api
  module V1
    module App
      class WhiteboardSnapshotsController < BaseController
        def index
          snapshots = find_chat_session.whiteboard_snapshots

          render json: {
            whiteboard_snapshots: snapshots.map { |snapshot| snapshot_payload(snapshot) }
          }
        end

        def show
          snapshot = find_chat_session.whiteboard_snapshots.find(params[:id])

          render json: snapshot_payload(snapshot, include_scene: true)
        end

        private

        def find_chat_session
          Current.user.chat_sessions.find(params[:chat_id])
        end

        def snapshot_payload(snapshot, include_scene: false)
          payload = {
            id: snapshot.id,
            name: snapshot.name,
            snapshot_kind: snapshot.snapshot_kind,
            element_count: snapshot.element_count,
            created_at: snapshot.created_at.iso8601
          }
          payload[:scene_json] = snapshot.scene_json if include_scene
          payload
        end
      end
    end
  end
end
