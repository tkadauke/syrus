class ProviderAuthFailure
  OUTCOME = "provider_auth_expired".freeze
  CLASSIFICATION = "provider_auth_expired".freeze

  PATTERNS = [
    /auth error code:\s*token_expired/i,
    /\btoken_expired\b/i,
    /failed to refresh (?:the )?(?:auth(?:entication)? )?token/i,
    /access token could not be refreshed/i,
    /authentication token (?:is )?expired/i,
    /sign in again/i,
    /logged out or signed in to another account/i,
    /signed out or signed in to another account/i,
    /\b(?:websocket|web socket|ws|http|status|code)?\s*401\b.{0,160}\bunauthori[sz]ed\b/i,
    /\bunauthori[sz]ed\b.{0,160}\b(?:websocket|web socket|ws|http|status|code)?\s*401\b/i
  ].freeze

  def self.detect?(text)
    PATTERNS.any? { |pattern| text.to_s.match?(pattern) }
  end
end
