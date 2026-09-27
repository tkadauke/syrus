require "net/http"

# Decides which MCP transport a workflow agent invocation should use: the
# persistent worker-local daemon (PersistentMcpDaemon) when the
# `persistent_mcp_sidecar` feature is on, the daemon answers a healthy
# #health_check, AND it advertises WORKFLOW_TOOLS_CAPABILITY -- or the
# existing per-run stdio sidecar (Mcp::Sidecar) otherwise. Every non-persistent
# outcome carries a `reason` string so callers can log actionable diagnostics
# instead of silently falling back (see AgentProviders::Base#log_mcp_transport_decision!).
#
# The daemon exposes one workflow MCP path per agent role. #select carries the
# requested role into the persistent decision so the agent's `tools/list`
# response is role-scoped instead of a daemon-wide workflow superset.
class WorkflowMcpTransportSelector
  Decision = Struct.new(:transport, :reason, :daemon_identity, :mcp_path, keyword_init: true) do
    def persistent? = transport == :persistent
    def stdio? = transport == :stdio
  end

  OPEN_TIMEOUT = 1
  READ_TIMEOUT = 1.5

  CONNECTION_ERRORS = [
    Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH,
    Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError
  ].freeze

  def self.select(host: PersistentMcpDaemon.host, port: PersistentMcpDaemon.port, role: AgentRole::WORKFLOW_IMPLEMENT)
    new(host: host, port: port, role: role).select
  end

  def initialize(host:, port:, role:)
    @host = host
    @port = port
    @role = role.to_s
  end

  def select
    return stdio_decision("feature_disabled") unless Feature.persistent_mcp_sidecar_enabled?

    health = fetch_health
    return stdio_decision(health[:reason]) unless health[:ok]
    return stdio_decision(incompatibility_reason(health[:body])) unless workflow_tools_supported?(health[:body])

    Decision.new(
      transport: :persistent,
      reason: nil,
      daemon_identity: health[:body]["identity"],
      mcp_path: PersistentMcpDaemon.workflow_role_path(@role)
    )
  rescue StandardError => e
    stdio_decision("selector_error: #{e.class}: #{e.message}")
  end

  private

  def stdio_decision(reason)
    Decision.new(transport: :stdio, reason: reason, daemon_identity: nil, mcp_path: nil)
  end

  def workflow_tools_supported?(body)
    Array(body["capabilities"]).include?(PersistentMcpDaemon::WORKFLOW_TOOLS_CAPABILITY)
  end

  def incompatibility_reason(body)
    capabilities = Array(body["capabilities"]).join(",").presence || "none"
    "daemon_incompatible: workflow_tools capability missing (capabilities=#{capabilities})"
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
