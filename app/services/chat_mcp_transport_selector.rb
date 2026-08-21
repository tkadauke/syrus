require "net/http"

# Chat-surface twin of WorkflowMcpTransportSelector (EPIC-250). Decides which
# MCP transport a chat turn should use: the persistent worker-local daemon
# (PersistentMcpDaemon) when the `persistent_mcp_sidecar` feature is on, the
# daemon answers a healthy #health_check, AND it advertises
# CHAT_TOOLS_CAPABILITY -- or the existing per-turn stdio sidecars
# (Mcp::Sidecar) otherwise. Every non-persistent outcome carries a `reason`
# string so callers can log actionable diagnostics instead of silently
# falling back (see ChatTurnJob#chat_mcp_transport_decision).
#
# Kept as a standalone twin of WorkflowMcpTransportSelector rather than a
# shared base class: the two selectors gate on different capabilities and
# evolve independently (chat and workflow tool wiring are separate EPIC-250
# milestones), so sharing the ~80 lines of HTTP/health-check plumbing would
# couple two still-moving pieces for little benefit.
class ChatMcpTransportSelector
  Decision = Struct.new(:transport, :reason, :daemon_identity, keyword_init: true) do
    def persistent? = transport == :persistent
    def stdio? = transport == :stdio
  end

  OPEN_TIMEOUT = 1
  READ_TIMEOUT = 1.5

  CONNECTION_ERRORS = [
    Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH,
    Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError
  ].freeze

  def self.select(host: PersistentMcpDaemon.host, port: PersistentMcpDaemon.port)
    new(host: host, port: port).select
  end

  def initialize(host:, port:)
    @host = host
    @port = port
  end

  def select
    return stdio_decision("feature_disabled") unless Feature.persistent_mcp_sidecar_enabled?

    health = fetch_health
    return stdio_decision(health[:reason]) unless health[:ok]
    return stdio_decision(incompatibility_reason(health[:body])) unless chat_tools_supported?(health[:body])

    Decision.new(transport: :persistent, reason: nil, daemon_identity: health[:body]["identity"])
  rescue StandardError => e
    stdio_decision("selector_error: #{e.class}: #{e.message}")
  end

  private

  def stdio_decision(reason)
    Decision.new(transport: :stdio, reason: reason, daemon_identity: nil)
  end

  def chat_tools_supported?(body)
    Array(body["capabilities"]).include?(PersistentMcpDaemon::CHAT_TOOLS_CAPABILITY)
  end

  def incompatibility_reason(body)
    capabilities = Array(body["capabilities"]).join(",").presence || "none"
    "daemon_incompatible: chat tool dispatch not yet supported (capabilities=#{capabilities})"
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
