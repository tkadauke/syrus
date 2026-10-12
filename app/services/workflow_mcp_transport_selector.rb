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
# Providers whose CLIs cannot speak HTTP MCP directly use bin/syrus-mcp-proxy
# as a secret-free stdio bridge to the daemon.
class WorkflowMcpTransportSelector < PersistentMcpTransportSelector
  Decision = Struct.new(:transport, :reason, :daemon_identity, :mcp_path, keyword_init: true) do
    def persistent? = transport == :persistent
    def stdio? = transport == :stdio
  end

  def self.select(host: PersistentMcpDaemon.host, port: PersistentMcpDaemon.port, role: AgentRole::WORKFLOW_IMPLEMENT)
    new(host: host, port: port, role: role).select
  end

  def initialize(host:, port:, role:)
    super(host: host, port: port)
    @role = role.to_s
  end

  private

  def stdio_decision(reason)
    Decision.new(transport: :stdio, reason: reason, daemon_identity: nil, mcp_path: nil)
  end

  def persistent_decision(body)
    Decision.new(
      transport: :persistent,
      reason: nil,
      daemon_identity: body["identity"],
      mcp_path: PersistentMcpDaemon.workflow_role_path(@role)
    )
  end

  def required_capability
    PersistentMcpDaemon::WORKFLOW_TOOLS_CAPABILITY
  end
end
