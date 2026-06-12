module Api
  module V1
    module App
      # JSON API for the browser SPA and app-scoped CLI calls. Browser
      # requests use session cookies; CLI requests may use bearer tokens.
      class BaseController < ApplicationController
        include ActionController::HttpAuthentication::Token::ControllerMethods

        skip_before_action :compute_system_alerts
        prepend_before_action :authenticate_bearer_token_if_present

        rescue_from ActiveRecord::RecordNotFound do |e|
          render_error("not_found", e.message, status: :not_found)
        end

        rescue_from ActionController::ParameterMissing do |e|
          render_error("bad_request", e.message, status: :bad_request)
        end

        private

        def require_authentication
          return if Current.user

          super
        end

        def authenticate_bearer_token_if_present
          return if Current.user

          token = request.authorization.to_s[/\ABearer\s+(.+)\z/, 1]
          Current.api_user = User.find_by(api_token: token) if token.present?
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
