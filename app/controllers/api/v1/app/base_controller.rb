module Api
  module V1
    module App
      # Session-cookie JSON API for the browser SPA. This is separate
      # from Api::BaseController, which is token-authenticated for
      # external callers.
      class BaseController < ApplicationController
        include ActionController::HttpAuthentication::Token::ControllerMethods

        skip_before_action :compute_system_alerts

        rescue_from ActiveRecord::RecordNotFound do |e|
          render_error("not_found", e.message, status: :not_found)
        end

        rescue_from ActionController::ParameterMissing do |e|
          render_error("bad_request", e.message, status: :bad_request)
        end

        private

        def resume_session
          super || resume_api_token_session
        end

        def resume_api_token_session
          authenticate_with_http_token do |token, _options|
            user = User.find_by(api_token: token)
            Current.session = Session.new(user: user) if user
          end
        end

        def request_authentication
          render_error("unauthorized", "Sign in to use the app API.", status: :unauthorized)
        end

        def require_admin
          return if Current.user&.admin?

          render_error("forbidden", "Admin access required.", status: :forbidden)
        end

        def render_error(code, message, status:)
          render json: { error: { code: code, message: message } }, status: status
        end
      end
    end
  end
end
