module Api
  module V1
    module App
      class LocalDaemonSessionsController < BaseController
        before_action :require_local_mode_feature

        def create
          chat_session = Current.user.chat_sessions.find_by!(id: params[:chat_id])
          return render_not_local_mode unless chat_session.mode == "local"

          chat_session.local_daemon_session&.destroy

          session = chat_session.create_local_daemon_session!(
            user: Current.user,
            repo_slug: daemon_params[:repo_slug],
            repo_root: daemon_params[:repo_root],
            branch: daemon_params[:branch],
            auth_token: SecureRandom.urlsafe_base64(32)
          )

          render json: {
            daemon_session_id: session.id,
            auth_token: session.auth_token
          }, status: :created
        end

        private

        def require_local_mode_feature
          render_error("feature_disabled", "Local Mode is not enabled.", status: :not_found) unless Feature.local_mode_enabled?
        end

        def render_not_local_mode
          render_error("invalid_mode", "Chat session must be in local mode.", status: :unprocessable_entity)
        end

        def daemon_params
          params.permit(:repo_slug, :repo_root, :branch)
        end
      end
    end
  end
end
