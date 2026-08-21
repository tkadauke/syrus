require "puma"
require "mcp"
require "json"

# Worker-local, persistent MCP sidecar daemon skeleton (EPIC-250: persistent
# MCP sidecar and tool usage visibility). Disabled by default behind the
# `persistent_mcp_sidecar` feature — #start refuses to boot while the
# feature is off, and nothing else in the codebase points an agent's MCP
# transport at this daemon, so workflow and chat agents keep spawning the
# existing per-run/per-session stdio sidecars (Mcp::Sidecar) unchanged.
#
# This is a skeleton, not a real tool surface: it proves the daemon can boot
# Rails once, hold one MCP::Server in memory, and answer a health/readiness
# check that enumerates tools and round-trips a no-op MCP request (the
# protocol-level `ping` method) — no workflow or chat agent capability is
# wired to it yet.
#
# Local-only: bound to loopback by default (SYRUS_PERSISTENT_MCP_HOST), and
# MCP requests are served through
# MCP::Server::Transports::StreamableHTTPTransport in stateless mode, which
# independently enforces DNS-rebinding/loopback host protections.
class PersistentMcpDaemon
  DEFAULT_PORT = 4805
  DEFAULT_HOST = "127.0.0.1"

  HEALTH_PATH = "/healthz"
  MCP_PATH = "/mcp"

  # Key callers set in an MCP request's `_meta` to carry a signed
  # McpInvocationContext token. `_meta` is per-request (MCP::Server merges it
  # into the shared server_context Hash on every dispatch -- see
  # MCP::Server#server_context_with_meta), so this is how a per-call
  # context reaches a tool without any daemon-wide mutable "current
  # run"/"current chat" state.
  INVOCATION_CONTEXT_META_KEY = :syrus_invocation_context

  def self.port
    Integer(ENV.fetch("SYRUS_PERSISTENT_MCP_PORT", DEFAULT_PORT))
  end

  def self.host
    ENV.fetch("SYRUS_PERSISTENT_MCP_HOST", DEFAULT_HOST)
  end

  def self.start(host: self.host, port: self.port)
    new(host: host, port: port).tap(&:start)
  end

  def initialize(host: self.class.host, port: self.class.port)
    @host = host
    @port = port
    @started_at = nil
  end

  def start
    raise "PersistentMcpDaemon: the persistent_mcp_sidecar feature is disabled" unless Feature.persistent_mcp_sidecar_enabled?
    raise "PersistentMcpDaemon: already started" if @server

    @started_at = Time.current
    @server = Puma::Server.new(method(:call))
    @server.add_tcp_listener(@host, @port)
    @thread = @server.run(true, thread_name: "persistent-mcp-daemon")
    Rails.logger.info("[PersistentMcpDaemon] listening on #{@host}:#{@port} worker_id=#{identity[:worker_id]}")
    self
  end

  # Blocks the caller until the server thread exits (SIGTERM/SIGINT handler
  # calling #stop, or a fatal error). Entry points call this to stay alive.
  def join
    @thread&.join
  end

  def stop
    return unless @server

    @server.stop(true)
    Rails.logger.info("[PersistentMcpDaemon] stopped")
  end

  # Rack entry point — also used directly by tests via Rack::MockRequest,
  # without opening a real TCP listener.
  def call(env)
    request = Rack::Request.new(env)

    if request.path == HEALTH_PATH
      health_response
    elsif request.path == MCP_PATH || request.path.start_with?("#{MCP_PATH}/")
      mcp_transport.call(env)
    else
      not_found
    end
  rescue StandardError => e
    Rails.logger.error("[PersistentMcpDaemon] #{e.class}: #{e.message}")
    json_response(500, error: "internal_error")
  end

  # Stable worker-local identity for diagnostics. Reuses
  # WorkerStorageIdentity's existing per-data-root UUID (already the stable
  # per-worker identity used for resume-queue routing) instead of minting a
  # parallel identity file; `pid` distinguishes the current process instance
  # across restarts of the same worker.
  def identity
    {
      worker_id: WorkerStorageIdentity.key,
      hostname: SyrusVersion.hostname,
      role: SyrusVersion.role,
      version: SyrusVersion.current,
      pid: Process.pid
    }
  end

  def mcp_server
    @mcp_server ||= MCP::Server.new(
      name: "syrus-persistent-mcp-daemon",
      tools: [ PersistentMcpDaemon::PingTool, PersistentMcpDaemon::InvocationContextTool ],
      server_context: { identity: identity }
    )
  end

  # Boots (or reuses) the in-memory MCP::Server, lists its tools, and
  # round-trips the protocol-level `ping` method — the "boot, enumerate
  # tools, accept a no-op request" proof this skeleton exists to provide.
  def health_check
    tools_result = dispatch("healthz-tools", "tools/list")
    ping_result = dispatch("healthz-ping", "ping")
    ping_ok = ping_result["result"] == {}

    {
      status: ping_ok ? "ok" : "error",
      identity: identity,
      started_at: @started_at&.utc&.iso8601,
      uptime_seconds: @started_at ? (Time.current - @started_at).round(1) : nil,
      tools: Array(tools_result.dig("result", "tools")).map { |tool| tool["name"] },
      ping_ok: ping_ok
    }
  rescue StandardError => e
    { status: "error", identity: identity, error: "#{e.class}: #{e.message}" }
  end

  private

  def dispatch(id, method)
    JSON.parse(mcp_server.handle_json({ jsonrpc: "2.0", id: id, method: method }.to_json))
  end

  def mcp_transport
    @mcp_transport ||= MCP::Server::Transports::StreamableHTTPTransport.new(mcp_server, stateless: true)
  end

  def health_response
    payload = health_check
    json_response(payload[:status] == "ok" ? 200 : 503, payload)
  end

  def not_found
    json_response(404, error: "not_found")
  end

  def json_response(status, payload)
    [ status, { "Content-Type" => "application/json" }, [ JSON.generate(payload) ] ]
  end
end
