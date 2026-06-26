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

        def create
          chat_session = find_chat_session
          snapshot = WhiteboardSnapshot.create_from_scene!(
            chat_session: chat_session,
            scene: plain_json(params.fetch(:scene_json)),
            kind: params.fetch(:snapshot_kind),
            name: params[:name].presence
          )

          render json: snapshot_payload(snapshot, include_scene: true), status: :created
        rescue ArgumentError => e
          render_error("bad_request", e.message, status: :bad_request)
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
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

        def plain_json(value)
          case value
          when ActionController::Parameters
            plain_json(value.to_unsafe_h)
          when Hash
            value.to_h.transform_values { |child| plain_json(child) }
          when Array
            value.map { |child| plain_json(child) }
          else
            value
          end
        end
      end
    end
  end
end
