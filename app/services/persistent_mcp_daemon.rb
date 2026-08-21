require "puma"
require "mcp"
require "json"
require "stringio"

# Worker-local, persistent MCP sidecar daemon (EPIC-250: persistent MCP
# sidecar and tool usage visibility). Disabled by default behind the
# `persistent_mcp_sidecar` feature — #start refuses to boot while the
# feature is off. WorkflowMcpTransportSelector and ChatMcpTransportSelector
# are the only things that decide whether a workflow agent invocation or a
# chat turn, respectively, actually points its MCP transport here instead of
# the existing per-run/per-turn stdio sidecars (Mcp::Sidecar); each requires
# the feature on, a passing #health_check, AND `capabilities` to include its
# own capability (WORKFLOW_TOOLS_CAPABILITY / CHAT_TOOLS_CAPABILITY),
# falling back to stdio (with a logged reason) otherwise. The two are
# independent: with the feature enabled, chat turns route here today, but
# workflow agents still always use stdio (see WORKFLOW_TOOLS_CAPABILITY).
#
# It proves the daemon can boot Rails once, hold one MCP::Server in memory,
# and answer a health/readiness check that enumerates tools and round-trips
# a no-op MCP request (the protocol-level `ping` method). The real chat MCP
# tool set (McpToolRegistry surface: :chat) is wired onto this daemon's
# MCP::Server (see #chat_tools, PersistentMcpDaemon::ChatToolDispatch), so
# CAPABILITIES advertises CHAT_TOOLS_CAPABILITY and ChatMcpTransportSelector
# can pick :persistent for a chat turn once this passes #health_check.
# CAPABILITIES does NOT yet include WORKFLOW_TOOLS_CAPABILITY -- wiring the
# real workflow tool set onto this daemon is a later EPIC-250 milestone, so
# WorkflowMcpTransportSelector still always falls back to stdio in production.
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

  # `claude`/`codex` build the outbound JSON-RPC body themselves -- there is
  # no config surface to make either CLI attach a custom `_meta` key to every
  # tool call. An HTTP header IS under Syrus's control (both CLIs support a
  # static `headers` map for HTTP-type MCP servers), so a caller that cannot
  # set `_meta` directly attaches its signed McpInvocationContext token here
  # instead, and #call bridges it into `_meta` (see #inject_invocation_context)
  # before dispatch -- tools keep reading a single, transport-agnostic place
  # (server_context[:_meta][INVOCATION_CONTEXT_META_KEY]).
  INVOCATION_CONTEXT_HEADER = "X-Syrus-Invocation-Context"
  INVOCATION_CONTEXT_HEADER_ENV_KEY = "HTTP_X_SYRUS_INVOCATION_CONTEXT"

  # Advertised in #health_check's `capabilities` array once a chat turn's
  # real tool set (McpToolRegistry surface: :chat, the same tools the stdio
  # chat sidecars serve) is wired onto this daemon's MCP::Server -- see
  # #chat_tools and PersistentMcpDaemon::ChatToolDispatch. ChatMcpTransportSelector
  # requires this before routing a chat turn's MCP traffic here.
  CHAT_TOOLS_CAPABILITY = "chat_tools"
  CAPABILITIES = [ CHAT_TOOLS_CAPABILITY ].freeze

  # NOT yet included in CAPABILITIES: wiring a workflow's real tool set
  # (Mcp::Tools, the same tools the stdio sidecar serves) onto this daemon's
  # MCP::Server is a later EPIC-250 milestone. Until then this daemon only
  # exposes its proof-of-pipe tools (daemon_ping, daemon_invocation_context)
  # plus the chat tool set above, so WorkflowMcpTransportSelector always
  # falls callers back to the stdio sidecar in production. Tests exercise
  # the persistent-transport path by stubbing a health response that
  # includes this capability.
  WORKFLOW_TOOLS_CAPABILITY = "workflow_tools"

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
      mcp_transport.call(inject_invocation_context(env))
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
      tools: [ PersistentMcpDaemon::PingTool, PersistentMcpDaemon::InvocationContextTool ] + chat_tools,
      server_context: { identity: identity }
    )
  end

  # The full known chat MCP tool surface (every surface: :chat entry in
  # McpToolRegistry, essential and deferred tiers combined), each wrapped so
  # a call resolves its own per-invocation chat_session/tier/role from the
  # signed McpInvocationContext token in that request's `_meta` -- see
  # PersistentMcpDaemon::ChatToolDispatch for why a single static tool list
  # has to be the superset rather than a tier-exact one, and
  # PersistentMcpDaemon::ChatContextResolver for how the security-relevant
  # tiering/role/feature-flag gate is still enforced per call.
  def chat_tools
    @chat_tools ||= McpToolRegistry.tools(surface: :chat).uniq.map { |tool| PersistentMcpDaemon::ChatToolDispatch.wrap(tool) }
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
      capabilities: self.class::CAPABILITIES,
      ping_ok: ping_ok
    }
  rescue StandardError => e
    { status: "error", identity: identity, error: "#{e.class}: #{e.message}" }
  end

  private

  # Bridges INVOCATION_CONTEXT_HEADER into the JSON-RPC request's
  # `params._meta` so MCP::Server#server_context_with_meta (and, downstream,
  # tools reading server_context[:_meta]) see it exactly as they would if the
  # MCP client itself had set `_meta` -- see the constant comment above for
  # why a header bridge is necessary. A no-op (env returned unchanged) unless
  # the header is present on a POST with a single JSON-RPC object body;
  # anything else is left for the transport's own validation to reject.
  def inject_invocation_context(env)
    token = env[INVOCATION_CONTEXT_HEADER_ENV_KEY]
    return env if token.blank? || env["REQUEST_METHOD"] != "POST"

    request = Rack::Request.new(env)
    body_string = request.body.read
    request.body.rewind

    parsed = JSON.parse(body_string, symbolize_names: true)
    return env unless parsed.is_a?(Hash) && parsed[:method]

    params = parsed[:params].is_a?(Hash) ? parsed[:params] : {}
    meta = params[:_meta].is_a?(Hash) ? params[:_meta] : {}
    parsed[:params] = params.merge(_meta: meta.merge(INVOCATION_CONTEXT_META_KEY => token))

    new_body = JSON.generate(parsed)
    new_env = env.dup
    new_env["rack.input"] = StringIO.new(new_body)
    new_env["CONTENT_LENGTH"] = new_body.bytesize.to_s
    new_env
  rescue JSON::ParserError
    env
  end

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
