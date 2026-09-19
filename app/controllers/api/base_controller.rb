module Api
  # Shared base for /api/* controllers — JSON-only, token-based
  # auth via `Authorization: Bearer <token>` header. Errors come
  # back as `{ "error": { "code": "...", "message": "..." } }`
  # with the appropriate HTTP status. No HTML responses; no
  # cookies; no CSRF (this is API-key auth, not session auth).
  class BaseController < ActionController::API
    include ActionController::HttpAuthentication::Token::ControllerMethods
    include JobEpicRefFinder
    include PerformanceLoggingContext
    include JsonErrorRendering

    # Only failed token lookups count against this limit, so a well-behaved
    # client with a valid (even high-volume) token is never throttled — this
    # exists purely to slow down repeated bad-bearer-token guessing, the way
    # SessionsController already throttles repeated bad passwords.
    BAD_API_TOKEN_LIMIT = 20
    BAD_API_TOKEN_WINDOW = 5.minutes

    before_action :authenticate_via_api_token
    around_action :switch_locale

    rescue_from ActiveRecord::RecordNotFound do |e|
      render_error("not_found", e.message, status: :not_found)
    end

    rescue_from ActionController::ParameterMissing do |e|
      render_error("bad_request", e.message, status: :bad_request)
    end

    private

    def authenticate_via_api_token
      return render_bad_api_token_rate_limited if bad_api_token_rate_limited?

      authenticated = authenticate_or_request_with_http_token do |token, _options|
        # Look up by deterministic-encrypted column — same plaintext
        # always encrypts to the same ciphertext, so a WHERE works.
        # ActiveSupport::SecurityUtils.secure_compare is wrapped by
        # AR's encryption layer; no separate timing-safe step needed.
        @current_api_user = User.find_by(api_token: token)
      end
      record_bad_api_token_attempt if @current_api_user.nil?
      refresh_performance_logging_user_context if @current_api_user
      authenticated
    end

    def bad_api_token_rate_limited?
      cache_store.read(bad_api_token_cache_key).to_i >= BAD_API_TOKEN_LIMIT
    end

    def record_bad_api_token_attempt
      cache_store.increment(bad_api_token_cache_key, 1, expires_in: BAD_API_TOKEN_WINDOW)
    end

    def bad_api_token_cache_key
      ["rate-limit", "api-bad-token", request.remote_ip].join(":")
    end

    def render_bad_api_token_rate_limited
      render_error("rate_limited", I18n.t("api.base.rate_limited"), status: :too_many_requests)
    end

    def switch_locale(&action)
      locale = current_api_user&.locale.presence || I18n.default_locale
      I18n.with_locale(locale, &action)
    end

    def request_http_token_authentication(realm = "Syrus API", message = nil)
      render_error("unauthorized",
                   I18n.t("api.base.unauthorized"),
                   status: :unauthorized)
    end

    def current_api_user
      @current_api_user
    end

    def performance_logging_user_id
      current_api_user&.id
    end

    def performance_logging_admin?
      current_api_user&.admin?
    end

    def require_admin_api
      return if current_api_user&.admin?
      render_error("forbidden", I18n.t("api.base.admin_required"), status: :forbidden)
    end
  end
end
