require "socket"

# Owns the trusted Rails side of chat's stdio compatibility path.
#
# The agent-visible MCP config remains secret-free and still points at a stdio
# command, but that command is bin/syrus-mcp-proxy. This worker-owned fallback
# daemon is started outside the agent process and receives signed per-turn
# invocation tokens, so chat gets the same context-scoped tool surface as the
# persistent daemon without putting boot secrets into mcp.json.
class ChatMcpStdioFallback
  class << self
    def server
      @mutex ||= Mutex.new
      @mutex.synchronize do
        return @server if @server&.started?

        @server = new.start
      end
    end

    def reset_for_test!
      @mutex ||= Mutex.new
      @mutex.synchronize do
        @server&.stop
        @server = nil
      end
    end
  end

  attr_reader :daemon, :url, :identity

  def start
    @daemon = PersistentMcpDaemon.start(
      host: PersistentMcpDaemon.host,
      port: available_port,
      require_feature: false
    )
    @url = "http://#{PersistentMcpDaemon.host}:#{@port}#{PersistentMcpDaemon::MCP_PATH}"
    @identity = @daemon.identity
    Rails.logger.info("[ChatMcpStdioFallback] listening on #{@url} worker_id=#{@identity[:worker_id]}")
    self
  end

  def started?
    @daemon&.started?
  end

  def stop
    @daemon&.stop
  end

  private

  def available_port
    server = TCPServer.new(PersistentMcpDaemon.host, 0)
    @port = server.addr[1]
  ensure
    server&.close
  end
end
