module Api
  module V1
    module App
      class ChatWhiteboardsController < BaseController
        def show
          whiteboard = Whiteboard::Board.for(find_chat_session)
          fresh_when(etag: whiteboard&.version || 0, public: false)
          return if performed?
          render json: whiteboard_payload(whiteboard, fields: params[:fields])
        end

        def files
          whiteboard = Whiteboard::Board.for(find_chat_session)
          fresh_when(etag: whiteboard&.version || 0, public: false)
          return if performed?
          render json: { files: whiteboard&.files || {} }
        end

        def update
          chat_session = find_chat_session
          elements = params.fetch(:elements)
          unless elements.is_a?(Array)
            render_error("bad_request", "elements must be an array", status: :bad_request)
            return
          end

          if elements.size > Whiteboard::Board::MAX_ELEMENTS
            render_error("element_limit", Whiteboard::Board.element_limit_message, status: :unprocessable_content)
            return
          end

          scene = {
            "elements" => plain_json(elements),
            "appState" => plain_json(params[:appState] || params[:app_state] || {}),
            "files" => plain_json(params[:files] || {})
          }
          expected_version = params.fetch(:expected_version).to_i
          status = :ok
          whiteboard = nil

          chat_session.with_lock do
            whiteboard = Whiteboard::Board.for!(chat_session)
            if expected_version == whiteboard.version
              whiteboard.replace_scene!(scene)
            else
              status = :conflict
            end
          end

          payload = status == :conflict ? whiteboard_payload(whiteboard, include_files: true) : { version: whiteboard.version }
          render json: payload, status: status
        rescue ArgumentError => e
          render_error("bad_request", e.message, status: :bad_request)
        end

        private

        def find_chat_session
          Current.user.accessible_chat_sessions.find(params[:id])
        end

        def whiteboard_payload(whiteboard, fields: nil, include_files: false)
          return { version: whiteboard&.version || 0 } if fields == "version"
          scene = whiteboard ? whiteboard.current_state.except("version") : Whiteboard::Board.default_scene
          scene = scene.except("files") unless include_files
          {
            scene_json: scene,
            version: whiteboard&.version || 0
          }
        end
      end
    end
  end
end
