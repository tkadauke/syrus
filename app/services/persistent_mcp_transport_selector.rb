require "net/http"

class PersistentMcpTransportSelector
  OPEN_TIMEOUT = 1
  READ_TIMEOUT = 1.5

  CONNECTION_ERRORS = [
    Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH,
    Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError
  ].freeze

  def initialize(host:, port:)
    @host = host
    @port = port
  end

  def select
    return stdio_decision("feature_disabled") unless Feature.persistent_mcp_sidecar_enabled?

    PersistentMcpDaemon.ensure_started
    health = fetch_health
    return stdio_decision(health[:reason]) unless health[:ok]
    return stdio_decision(incompatibility_reason(health[:body])) unless required_capability_supported?(health[:body])

    persistent_decision(health[:body])
  rescue StandardError => e
    stdio_decision("selector_error: #{e.class}: #{e.message}")
  end

  private

  def stdio_decision(_reason)
    raise NotImplementedError
  end

  def persistent_decision(_body)
    raise NotImplementedError
  end

  def required_capability
    raise NotImplementedError
  end

  def required_capability_supported?(body)
    Array(body["capabilities"]).include?(required_capability)
  end

  def incompatibility_reason(body)
    capabilities = Array(body["capabilities"]).join(",").presence || "none"
    "daemon_incompatible: missing #{required_capability} capability (capabilities=#{capabilities})"
  end

  def fetch_health
    response = Net::HTTP.start(@host, @port, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      http.get(PersistentMcpDaemon::HEALTH_PATH)
    end
    parse_health(response)
  rescue *CONNECTION_ERRORS => e
    { ok: false, reason: "daemon_unreachable: #{e.class}: #{e.message}" }
  end

  def parse_health(response)
    return { ok: false, reason: "daemon_unhealthy: HTTP #{response.code}" } unless response.is_a?(Net::HTTPSuccess)

    body = JSON.parse(response.body)
    return { ok: false, reason: "daemon_unhealthy: status=#{body['status'].inspect}" } unless body["status"] == "ok"

    { ok: true, body: body }
  rescue JSON::ParserError => e
    { ok: false, reason: "daemon_unhealthy: invalid health response (#{e.message})" }
  end
end
