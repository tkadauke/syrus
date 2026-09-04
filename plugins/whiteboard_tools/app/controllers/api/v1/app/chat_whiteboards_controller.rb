module Api
  module V1
    module App
      class ChatWhiteboardsController < BaseController
        def show
          render json: whiteboard_payload(WhiteboardTools::Board.for(find_chat_session))
        end

        def update
          chat_session = find_chat_session
          elements = params.fetch(:elements)
          unless elements.is_a?(Array)
            render_error("bad_request", "elements must be an array", status: :bad_request)
            return
          end

          if elements.size > WhiteboardTools::Board::MAX_ELEMENTS
            render_error("element_limit", WhiteboardTools::Board.element_limit_message, status: :unprocessable_content)
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
            whiteboard = WhiteboardTools::Board.for!(chat_session)
            if expected_version == whiteboard.version
              whiteboard.replace_scene!(scene)
            else
              status = :conflict
            end
          end

          render json: whiteboard_payload(whiteboard), status: status
        rescue ArgumentError => e
          render_error("bad_request", e.message, status: :bad_request)
        end

        private

        def find_chat_session
          Current.user.accessible_chat_sessions.find(params[:id])
        end

        def whiteboard_payload(whiteboard)
          {
            scene_json: whiteboard ? whiteboard.current_state.except("version") : WhiteboardTools::Board.default_scene,
            version: whiteboard&.version || 0
          }
        end
      end
    end
  end
end
