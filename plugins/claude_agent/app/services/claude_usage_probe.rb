require "json"
require "net/http"
require "uri"

# Proactive ground-truth signal for Claude/Anthropic usage, mirroring
# CodexUsageProbe. Unlike Codex, there is no local auth.json to read
# structured usage from, so this makes a minimal `/v1/messages` call with
# the user's stored Claude Code OAuth token and reads Anthropic's "unified"
# rate-limit response headers (the same ones `claude` itself observes on
# every inference call).
class ClaudeUsageProbe
  MESSAGES_URL = "https://api.anthropic.com/v1/messages"
  ANTHROPIC_VERSION = "2023-06-01"
  # Claude Code's OAuth token is only accepted on /v1/messages when this
  # beta flag is sent - without it Anthropic returns 401/403 even for a
  # valid token, since token exchange (see ClaudeOauth) authenticates
  # against console.anthropic.com under a different flow than direct
  # Messages API calls.
  OAUTH_BETA_HEADER = "oauth-2025-04-20"
  PROBE_MODEL = "claude-haiku-4-5-20251001"
  DEFAULT_TIMEOUT_SECONDS = 10
  STALE_AFTER = 10.minutes

  EXHAUSTED_UTILIZATION_PERCENT = 100.0
  WARNING_UTILIZATION_PERCENT = 85.0

  Result = Data.define(:status, :snapshot, :message)

  class << self
    def refresh_for(user:, force: false)
      new(user: user).refresh(force: force)
    end

    def stale?(user, now: Time.current)
      evidence = latest_probe_evidence(user)
      return true if evidence.blank?

      evidence.observed_at < now - STALE_AFTER
    end

    def latest_probe_evidence(user)
      ProviderAvailabilityEvidence
        .where(user: user, provider: "claude", source: "usage_probe")
        .recent
        .first
    end
  end

  def initialize(user:, http: Net::HTTP, messages_url: ENV.fetch("CLAUDE_USAGE_PROBE_URL", MESSAGES_URL))
    @user = user
    @http = http
    @messages_url = messages_url
  end

  def refresh(force: false)
    return stored_result if !force && !self.class.stale?(@user)

    token = @user.claude_oauth_token.presence
    return persist(status: "unsupported", snapshot: {}, message: "Claude usage probing requires a Claude OAuth token.", http_status: nil) if token.blank?

    response = request_probe(token: token)
    return persist_http_failure(response) unless response.is_a?(Net::HTTPSuccess)

    snapshot = normalize_snapshot(response)
    return persist_inconclusive_headers(response) if snapshot.blank?

    persist(status: classify(snapshot), snapshot: snapshot, message: message_for(snapshot), http_status: response.code.to_i)
  rescue StandardError => e
    Rails.logger.warn("Claude usage probe failed for user #{@user.id}: #{e.class}: #{e.message}")
    persist(status: "probe_unavailable", snapshot: {}, message: e.message, http_status: nil)
  end

  private

  def stored_result
    evidence = self.class.latest_probe_evidence(@user)
    return Result.new(status: "unsupported", snapshot: {}, message: nil) if evidence.blank?

    Result.new(status: evidence.status, snapshot: evidence.details&.dig("snapshot") || {}, message: nil)
  end

  def request_probe(token:)
    uri = URI.parse(@messages_url)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["anthropic-version"] = ANTHROPIC_VERSION
    request["anthropic-beta"] = OAUTH_BETA_HEADER
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(
      model: PROBE_MODEL,
      max_tokens: 1,
      messages: [ { role: "user", content: "." } ]
    )

    @http.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                open_timeout: DEFAULT_TIMEOUT_SECONDS, read_timeout: DEFAULT_TIMEOUT_SECONDS) do |client|
      client.request(request)
    end
  end

  def persist_http_failure(response)
    status =
      case response
      when Net::HTTPUnauthorized, Net::HTTPForbidden
        "auth_error"
      when Net::HTTPTooManyRequests
        "probe_inconclusive"
      else
        "probe_inconclusive"
      end
    payload = JSON.parse(response.body.to_s) rescue {}
    snapshot = {
      "http_status" => response.code.to_i,
      "error" => payload.presence || response.body.to_s.truncate(500)
    }
    persist(status: status, snapshot: snapshot, message: "Claude usage probe returned HTTP #{response.code}.", http_status: response.code.to_i)
  end

  def persist_inconclusive_headers(response)
    persist(
      status: "probe_inconclusive",
      snapshot: { "http_status" => response.code.to_i },
      message: "Claude usage probe succeeded but returned no rate-limit headers.",
      http_status: response.code.to_i
    )
  end

  def normalize_snapshot(response)
    session_utilization = header_percent(response, "anthropic-ratelimit-unified-5h-utilization")
    weekly_utilization = header_percent(response, "anthropic-ratelimit-unified-7d-utilization")
    return {} if session_utilization.nil? && weekly_utilization.nil?

    {
      "source" => "anthropic_messages_headers",
      "representative_claim" => response["anthropic-ratelimit-unified-representative-claim"],
      "session_pct" => session_utilization,
      "session_reset_minutes" => minutes_until(header_epoch(response, "anthropic-ratelimit-unified-5h-reset")),
      "weekly_pct" => weekly_utilization,
      "weekly_reset_minutes" => minutes_until(header_epoch(response, "anthropic-ratelimit-unified-7d-reset"))
    }.compact
  end

  def classify(snapshot)
    worst = [ snapshot["session_pct"], snapshot["weekly_pct"] ].compact.max
    return "available" if worst.nil?
    return "exhausted" if worst >= EXHAUSTED_UTILIZATION_PERCENT
    return "warning" if worst >= WARNING_UTILIZATION_PERCENT

    "available"
  end

  def message_for(snapshot)
    status = classify(snapshot)
    return "Claude usage limit has been reached." if status == "exhausted"
    return "Claude usage is at #{limit_breakdown(snapshot)}." if status == "warning"

    "Claude usage snapshot refreshed (#{limit_breakdown(snapshot)})."
  end

  def limit_breakdown(snapshot)
    [
      snapshot["session_pct"] && "session #{snapshot['session_pct'].round}% used",
      snapshot["weekly_pct"] && "weekly #{snapshot['weekly_pct'].round}% used"
    ].compact.join(", ")
  end

  def persist(status:, snapshot:, message:, http_status:)
    ProviderAvailabilityEvidence.record_claude_probe!(
      user: @user,
      status: status,
      snapshot: snapshot,
      message: message,
      http_status: http_status,
      observed_at: Time.current
    )
    App::ProviderAvailability.clear_cache!(user: @user, provider: "claude")
    Result.new(status: status, snapshot: snapshot, message: message)
  end

  def header_percent(response, name)
    value = header_float(response, name)
    return if value.nil?

    (value * 100).round(1)
  end

  def header_float(response, name)
    raw = response[name]
    return if raw.blank?

    Float(raw)
  rescue ArgumentError, TypeError
    nil
  end

  def header_epoch(response, name)
    raw = response[name]
    return if raw.blank?

    Time.zone.at(Integer(raw))
  rescue ArgumentError, TypeError
    nil
  end

  def minutes_until(time)
    return if time.blank?

    ((time - Time.current) / 60).round
  end
end
