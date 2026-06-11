module Api
  module V1
    module App
      # JSON API for the browser SPA and narrow CLI actions. Browser requests
      # use the signed session cookie; CLI requests may use a bearer token.
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

        def require_authentication
          authenticate_via_api_token || super
        end

        def authenticate_via_api_token
          authenticate_with_http_token do |token, _options|
            user = User.find_by(api_token: token)
            Current.api_user = user if user
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
