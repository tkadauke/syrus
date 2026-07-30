require "base64"
require "json"
require "net/http"
require "uri"

class CodexUsageProbe
  CHATGPT_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
  DEFAULT_TIMEOUT_SECONDS = 10
  WARNING_REMAINING_PERCENT = 20.0

  Result = Data.define(:status, :snapshot, :message) do
    def ok?
      %w[ok warning exhausted unsupported].include?(status.to_s)
    end
  end

  class << self
    def refresh_for(user:, force: false)
      new(user: user).refresh(force: force)
    end

    def stale?(user, now: Time.current)
      return true if user.codex_usage_observed_at.blank?

      user.codex_usage_observed_at < 10.minutes.ago
    end
  end

  def initialize(user:, http: Net::HTTP, usage_url: ENV.fetch("CODEX_USAGE_URL", CHATGPT_USAGE_URL))
    @user = user
    @http = http
    @usage_url = usage_url
  end

  def refresh(force: false)
    return stored_result if !force && !self.class.stale?(@user)
    return persist(status: "unsupported", snapshot: {}, message: "Codex usage probing requires ChatGPT auth.json mode.") unless @user.codex_auth_mode == "chatgpt_login"

    auth = parse_auth_json
    token = auth.dig("tokens", "access_token").presence
    return persist(status: "unsupported", snapshot: {}, message: "Codex auth.json does not include an access token.") if token.blank?

    response = request_usage(auth: auth, token: token)
    return persist_http_failure(response) unless response.is_a?(Net::HTTPSuccess)

    payload = JSON.parse(response.body.to_s)
    snapshot = normalize_snapshot(payload)
    persist(status: classify(snapshot), snapshot: snapshot, message: message_for(snapshot))
  rescue JSON::ParserError => e
    persist(status: "error", snapshot: {}, message: "Codex usage response was not valid JSON: #{e.message}")
  rescue StandardError => e
    Rails.logger.warn("Codex usage probe failed for user #{@user.id}: #{e.class}: #{e.message}")
    persist(status: "error", snapshot: {}, message: e.message)
  end

  private

  def stored_result
    Result.new(
      status: @user.codex_usage_status,
      snapshot: @user.codex_usage_snapshot || {},
      message: nil
    )
  end

  def parse_auth_json
    JSON.parse(@user.codex_auth_json.to_s)
  rescue JSON::ParserError => e
    raise CodexAuth::Error, "Codex auth.json is not valid JSON: #{e.message}"
  end

  def request_usage(auth:, token:)
    uri = URI.parse(@usage_url)
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["User-Agent"] = "codex-cli"
    account_id = account_id_from(auth)
    request["ChatGPT-Account-ID"] = account_id if account_id.present?
    request["X-OpenAI-Fedramp"] = "true" if fedramp_account?(auth)

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
        "exhausted"
      else
        "error"
      end
    payload = JSON.parse(response.body.to_s) rescue {}
    snapshot = {
      "http_status" => response.code.to_i,
      "error" => payload.presence || response.body.to_s.truncate(500)
    }
    persist(status: status, snapshot: snapshot, message: "Codex usage probe returned HTTP #{response.code}.")
  end

  def normalize_snapshot(payload)
    primary = normalize_window(payload.dig("rate_limit", "primary_window"), secondary: false)
    secondary = normalize_window(payload.dig("rate_limit", "secondary_window"), secondary: true)
    additional = Array(payload["additional_rate_limits"]).filter_map do |entry|
      {
        "limit_id" => entry["metered_feature"],
        "limit_name" => entry["limit_name"],
        "primary" => normalize_window(entry.dig("rate_limit", "primary_window"), secondary: false),
        "secondary" => normalize_window(entry.dig("rate_limit", "secondary_window"), secondary: true)
      }.compact
    end

    {
      "source" => "chatgpt_wham_usage",
      "plan_type" => payload["plan_type"],
      "primary" => primary,
      "secondary" => secondary,
      "remaining_percent" => remaining_percent(primary, secondary),
      "credits" => normalize_credits(payload["credits"]),
      "spend_control" => normalize_spend_control(payload["spend_control"]),
      "rate_limit_reached_type" => payload.dig("rate_limit_reached_type", "kind") || payload["rate_limit_reached_type"],
      "additional_rate_limits" => additional
    }.compact
  end

  def normalize_window(window, secondary:)
    return unless window.is_a?(Hash)

    used_percent = numeric(window["used_percent"])
    window_minutes = window["limit_window_seconds"].present? ? (window["limit_window_seconds"].to_f / 60).round : nil
    {
      "label" => limit_label_for_window(window_minutes, secondary: secondary),
      "used_percent" => used_percent,
      "remaining_percent" => used_percent.nil? ? nil : [ 100.0 - used_percent, 0.0 ].max,
      "window_minutes" => window_minutes,
      "reset_after_seconds" => window["reset_after_seconds"],
      "reset_at" => epoch_time(window["reset_at"])
    }.compact
  end

  def normalize_credits(credits)
    return unless credits.is_a?(Hash)

    {
      "has_credits" => credits["has_credits"],
      "unlimited" => credits["unlimited"],
      "balance" => unwrap_nullable(credits["balance"])
    }.compact
  end

  def normalize_spend_control(spend_control)
    return unless spend_control.is_a?(Hash)

    limit = unwrap_nullable(spend_control["individual_limit"])
    normalized = { "reached" => spend_control["reached"] }
    if limit.is_a?(Hash)
      normalized["individual_limit"] = {
        "limit" => limit["limit"],
        "used" => limit["used"],
        "remaining_percent" => numeric(limit["remaining_percent"]),
        "reset_at" => epoch_time(limit["reset_at"])
      }.compact
    end
    normalized.compact
  end

  def classify(snapshot)
    return "exhausted" if snapshot["rate_limit_reached_type"].present?
    return "exhausted" if snapshot.dig("spend_control", "reached") == true

    remaining = snapshot["remaining_percent"]
    return "exhausted" if remaining.present? && remaining <= 0.0
    return "warning" if remaining.present? && remaining <= WARNING_REMAINING_PERCENT

    "ok"
  end

  def message_for(snapshot)
    remaining = snapshot["remaining_percent"]
    return "Codex usage limit has been reached." if classify(snapshot) == "exhausted"
    return "Codex usage has #{remaining.round}% remaining (#{limit_breakdown(snapshot)})." if remaining.present?

    "Codex usage snapshot refreshed."
  end

  def persist(status:, snapshot:, message:)
    @user.update!(
      codex_usage_status: status,
      codex_usage_observed_at: Time.current,
      codex_usage_snapshot: snapshot
    )
    Result.new(status: status, snapshot: snapshot, message: message)
  end

  def account_id_from(auth)
    auth.dig("tokens", "account_id").presence ||
      token_claim(auth, "chatgpt_account_id").presence ||
      jwt_claim(id_token(auth), [ "https://api.openai.com/auth", "chatgpt_account_id" ])
  end

  def fedramp_account?(auth)
    raw = token_claim(auth, "chatgpt_account_is_fedramp")
    return raw if raw == true || raw == false

    jwt_claim(id_token(auth), [ "https://api.openai.com/auth", "chatgpt_account_is_fedramp" ]) == true
  end

  def id_token(auth)
    auth.dig("tokens", "id_token")
  end

  def token_claim(auth, key)
    token = id_token(auth)
    token[key] if token.is_a?(Hash)
  end

  def jwt_claim(jwt, path)
    return unless jwt.is_a?(String)

    _header, payload, _signature = jwt.split(".", 3)
    return if payload.blank?

    decoded = Base64.urlsafe_decode64(payload.ljust((payload.length + 3) / 4 * 4, "="))
    path.reduce(JSON.parse(decoded)) { |memo, key| memo.is_a?(Hash) ? memo[key] : nil }
  rescue ArgumentError, JSON::ParserError
    nil
  end

  def remaining_percent(primary, secondary)
    [ primary, secondary ].filter_map { |window| window&.dig("remaining_percent") }.min
  end

  def limit_breakdown(snapshot)
    windows = [ snapshot["primary"], snapshot["secondary"] ].compact
    windows.filter_map do |window|
      remaining = window["remaining_percent"]
      next if remaining.blank?

      "#{window.fetch("label", "usage")} #{remaining.round}%"
    end.join(", ")
  end

  def limit_label_for_window(window_minutes, secondary:)
    duration_label_for(window_minutes) || (secondary ? "secondary usage" : "usage")
  end

  def duration_label_for(window_minutes)
    return if window_minutes.blank?

    minutes = [ window_minutes.to_i, 0 ].max
    return "5h" if approximate_window?(minutes, 5 * 60)
    return "daily" if approximate_window?(minutes, 24 * 60)
    return "weekly" if approximate_window?(minutes, 7 * 24 * 60)
    return "monthly" if approximate_window?(minutes, 30 * 24 * 60)
    return "annual" if approximate_window?(minutes, 365 * 24 * 60)

    nil
  end

  def approximate_window?(minutes, expected)
    tolerance = [ (expected.to_f * 0.10).round, 1 ].max
    (minutes - expected).abs <= tolerance
  end

  def numeric(value)
    return if value.nil?

    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def epoch_time(value)
    return if value.blank?

    Time.zone.at(value.to_i).iso8601
  end

  def unwrap_nullable(value)
    return value.first if value.is_a?(Array) && value.size == 1

    value
  end
end
