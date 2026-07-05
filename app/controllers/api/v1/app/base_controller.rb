module Api
  module V1
    module App
      # JSON API for the browser SPA and app-scoped CLI calls. Browser
      # requests use session cookies; CLI requests may use bearer tokens.
      class BaseController < ApplicationController
        include JobEpicRefFinder

        TokenSession = Struct.new(:user, keyword_init: true) do
          def destroy; end
        end

        skip_before_action :compute_system_alerts
        skip_forgery_protection if: :authenticated_bearer_token_request?

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
          user = bearer_token_user
          return unless user

          Current.session = TokenSession.new(user: user)
        end

        def authenticated_bearer_token_request?
          bearer_token_user.present?
        end

        def bearer_token_user
          token = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]
          return if token.blank?

          @bearer_token_user ||= User.find_by(api_token: token)
        end

        def request_authentication
          render_error("unauthorized", I18n.t("api.base.sign_in_required"), status: :unauthorized)
        end

        def require_admin
          return if Current.user&.admin?

          render_error("forbidden", I18n.t("api.base.admin_forbidden"), status: :forbidden)
        end

        def render_error(code, message, status:)
          render json: { error: { code: code, message: message } }, status: status
        end
      end
    end
  end
end
