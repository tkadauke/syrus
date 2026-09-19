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

    # Only a *present* token that fails to resolve to a user counts against
    # this limit — a request with no Authorization header, or one that isn't
    # `Token`/`Bearer <value>` shaped, is never counted, and a request that
    # does present a valid token is never blocked by it either, even mid
    # lockout. So a well-behaved client with a valid (even high-volume) token
    # is never throttled — this exists purely to slow down repeated
    # bad-bearer-token guessing, the way SessionsController already throttles
    # repeated bad passwords.
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
      # Parsed by hand rather than via authenticate_or_request_with_http_token:
      # that helper renders the 401 itself as soon as the block returns falsy,
      # which would happen before we know whether *this* request is even a
      # bad-token guess worth counting, and would double-render if we then
      # tried to swap in a 429. token_and_options returns nil unless the
      # header actually looks like `Token`/`Bearer <value>` — a missing or
      # malformed Authorization header never reaches here as a "bad token".
      token, = ActionController::HttpAuthentication::Token.token_and_options(request)

      if token.present?
        # Look up by deterministic-encrypted column — same plaintext
        # always encrypts to the same ciphertext, so a WHERE works.
        # ActiveSupport::SecurityUtils.secure_compare is wrapped by
        # AR's encryption layer; no separate timing-safe step needed.
        @current_api_user = User.find_by(api_token: token)
      end

      if @current_api_user
        refresh_performance_logging_user_context
        return true
      end

      if token.present?
        return render_bad_api_token_rate_limited if bad_api_token_rate_limited?

        record_bad_api_token_attempt
      end

      request_http_token_authentication
      false
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
