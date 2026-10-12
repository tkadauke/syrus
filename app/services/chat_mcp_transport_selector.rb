# Decides which MCP transport a chat turn should use: the persistent
# worker-local daemon when it is enabled, healthy, and advertises the chat tool
# capability, or the existing per-turn stdio sidecars otherwise.
class ChatMcpTransportSelector < PersistentMcpTransportSelector
  Decision = Struct.new(:transport, :reason, :daemon_identity, keyword_init: true) do
    def persistent? = transport == :persistent
    def stdio? = transport == :stdio
  end

  def self.select(host: PersistentMcpDaemon.host, port: PersistentMcpDaemon.port)
    new(host: host, port: port).select
  end

  private

  def stdio_decision(reason)
    Decision.new(transport: :stdio, reason: reason, daemon_identity: nil)
  end

  def persistent_decision(body)
    Decision.new(transport: :persistent, reason: nil, daemon_identity: body["identity"])
  end

  def required_capability
    PersistentMcpDaemon::CHAT_TOOLS_CAPABILITY
  end
end
