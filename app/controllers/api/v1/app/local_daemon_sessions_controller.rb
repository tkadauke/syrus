module Api
  module V1
    module App
      class LocalDaemonSessionsController < BaseController
        before_action :require_local_mode_feature
        before_action :find_chat_session

        # GET /api/v1/app/chats/:chat_id/local_daemon_session
        def show
          session = @chat_session.local_daemon_session
          return render_not_found unless session

          render json: { daemon_session: serialize(session) }
        end

        # POST /api/v1/app/chats/:chat_id/local_daemon_session
        # Creates a new daemon session (or re-uses an existing one).
        # Returns the auth_token the CLI uses to authenticate the WebSocket.
        def create
          session = @chat_session.local_daemon_session

          if session.nil?
            session = LocalDaemonSession.create!(
              chat_session: @chat_session,
              user: Current.user
            )
          elsif session.disconnected?
            session.update!(disconnected_at: nil, last_heartbeat_at: nil)
          end

          render json: { daemon_session: serialize(session, include_token: true) },
                 status: :created
        end

        # DELETE /api/v1/app/chats/:chat_id/local_daemon_session
        def destroy
          session = @chat_session.local_daemon_session
          session&.mark_disconnected!
          session&.destroy!

          head :no_content
        end

        private

        def find_chat_session
          @chat_session = Current.user.chat_sessions.find(params[:chat_id])
        end

        def require_local_mode_feature
          render_error("local_mode_disabled", "Local Mode is not enabled.", status: :not_found) unless Feature.local_mode_enabled?
        end

        def render_not_found
          render_error("not_found", "No daemon session exists for this chat.", status: :not_found)
        end

        def serialize(session, include_token: false)
          payload = {
            id: session.id,
            chat_session_id: session.chat_session_id,
            connected: session.connected?,
            daemon_repo: session.daemon_repo,
            daemon_branch: session.daemon_branch,
            last_heartbeat_at: session.last_heartbeat_at&.iso8601
          }
          payload[:auth_token] = session.auth_token if include_token
          payload
        end
      end
    end
  end
end
