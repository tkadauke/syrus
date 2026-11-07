module Api
  module V1
    module App
      class WhiteboardSnapshotsController < BaseController
        PER_PAGE = 30

        def index
          scope = Whiteboard::Snapshot.for(find_chat_session)
          page = [ params[:page].to_i, 1 ].max
          total = scope.count
          snapshots = scope.offset((page - 1) * PER_PAGE).limit(PER_PAGE)

          render json: {
            whiteboard_snapshots: snapshots.map { |snapshot| snapshot_payload(snapshot) },
            pagination: { page: page, per_page: PER_PAGE, total: total, total_pages: (total.to_f / PER_PAGE).ceil,
                          has_next_page: page * PER_PAGE < total, has_previous_page: page > 1 }
          }
        end

        def show
          snapshot = Whiteboard::Snapshot.for(find_chat_session).find(params[:id])

          render json: snapshot_payload(snapshot, include_scene: true)
        end

        def create
          chat_session = find_chat_session
          snapshot = Whiteboard::Snapshot.create_from_scene!(
            chat_session: chat_session,
            scene: plain_json(params.fetch(:scene_json)),
            kind: params.fetch(:snapshot_kind),
            name: params[:name].presence
          )

          render json: snapshot_payload(snapshot), status: :created
        rescue ArgumentError => e
          render_error("bad_request", e.message, status: :bad_request)
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        private

        def find_chat_session
          Current.user.accessible_chat_sessions.find(params[:chat_id])
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
