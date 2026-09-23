# The brute-force brake on the credential endpoints (sign in, password reset,
# passkey registration): 10 attempts per 3 minutes per IP.
#
# The E2E suite is the one legitimate caller that trips it. Every spec signs in,
# they all arrive from one address, and there are far more than ten of them, so
# the suite throttles itself: the first handful pass and every later spec fails
# on the sign-in page, which reads like a broken app rather than a hit rate
# limit. SYRUS_DISABLE_AUTH_RATE_LIMIT lifts the brake for that harness.
#
# Production ignores the variable outright. A brute-force defense that an
# environment variable can switch off is not a defense, and nothing about the
# harness needs it there.
class AuthRateLimit
  DISABLE_ENV_VAR = "SYRUS_DISABLE_AUTH_RATE_LIMIT".freeze

  def self.enabled?
    return true if Rails.env.production?

    ENV[DISABLE_ENV_VAR] != "1"
  end
end
