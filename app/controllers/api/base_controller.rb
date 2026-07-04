module Api
  # Shared base for /api/* controllers — JSON-only, token-based
  # auth via `Authorization: Bearer <token>` header. Errors come
  # back as `{ "error": { "code": "...", "message": "..." } }`
  # with the appropriate HTTP status. No HTML responses; no
  # cookies; no CSRF (this is API-key auth, not session auth).
  class BaseController < ActionController::API
    include ActionController::HttpAuthentication::Token::ControllerMethods

    before_action :authenticate_via_api_token

    rescue_from ActiveRecord::RecordNotFound do |e|
      render_error("not_found", e.message, status: :not_found)
    end

    rescue_from ActionController::ParameterMissing do |e|
      render_error("bad_request", e.message, status: :bad_request)
    end

    private

    def authenticate_via_api_token
      authenticate_or_request_with_http_token do |token, _options|
        # Look up by deterministic-encrypted column — same plaintext
        # always encrypts to the same ciphertext, so a WHERE works.
        # ActiveSupport::SecurityUtils.secure_compare is wrapped by
        # AR's encryption layer; no separate timing-safe step needed.
        @current_api_user = User.find_by(api_token: token)
      end
    end

    def request_http_token_authentication(realm = "Syrus API", message = nil)
      render_error("unauthorized",
                   I18n.t("api.base.unauthorized"),
                   status: :unauthorized)
    end

    def current_api_user
      @current_api_user
    end

    def require_admin_api
      return if current_api_user&.admin?
      render_error("forbidden", I18n.t("api.base.admin_required"), status: :forbidden)
    end

    def render_error(code, message, status:)
      render json: { error: { code: code, message: message } }, status: status
    end
  end
end
