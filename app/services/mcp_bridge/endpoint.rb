require "mcp"

module McpBridge
  # /mcp/bridge: the chat MCP tool surface over streamable HTTP, for an
  # external MCP client authenticated with an McpBridgeToken.
  #
  # It is a transport, not a second policy. The client gets exactly the tools
  # Mcp::Sidecar.chat_tools offers its bridge chat, already wrapped in the
  # same authorization gate, so essentials stay non-deniable, deniable tools
  # consult the operator's rules, and anything that needs a decision becomes
  # a confirmation card or authorization request in that chat. Every
  # tools/call is recorded in McpToolUsage like any other chat call.
  #
  # Each HTTP request builds its own MCP::Server and stateless transport --
  # the gem's Rails-controller pattern -- so no session or tool list
  # outlives one request and a revoked token stops working at once.
  class Endpoint
    PATH = "/mcp/bridge".freeze
    SERVER_NAME = "syrus".freeze
    BAD_TOKEN_LIMIT = 20
    BAD_TOKEN_WINDOW = 5.minutes

    def self.call(env) = new.call(env)

    def call(env)
      request = Rack::Request.new(env)
      plaintext = bearer_token(request)
      return rate_limited if plaintext.present? && bad_token_limited?(request)

      token = McpBridgeToken.authenticate(plaintext)
      unless token
        record_bad_token(request) if plaintext.present?
        return unauthorized
      end

      token.touch_last_used!
      chat = token.bridge_chat!
      I18n.with_locale(token.user.locale.presence || I18n.default_locale) do
        record_usage(request, chat) { transport_for(chat, request).call(env) }
      end
    end

    private

    def transport_for(chat, request)
      server = MCP::Server.new(
        name: SERVER_NAME,
        version: SyrusVersion.current.to_s,
        tools: Mcp::Sidecar.chat_tools(chat, tier: :all),
        server_context: Mcp::Sidecar.chat_context(chat, current_message_id: nil)
      )
      MCP::Server::Transports::StreamableHTTPTransport.new(
        server,
        stateless: true,
        enable_json_response: true,
        serve_subscriptions_listen: false,
        # A bearer token, not ambient browser credentials, authorizes this
        # endpoint, and Rails' host authorization has already admitted the
        # Host header; accept the instance's own hostname.
        allowed_hosts: [ request.host ]
      )
    end

    # Records tools/call requests the way the persistent daemon does at its
    # dispatch boundary. The JSON-RPC envelope is read before dispatch and
    # the result after, so a tool the gate refused still shows up.
    def record_usage(request, chat)
      call = tool_call(request)
      return yield unless call

      recorder = McpToolUsageRecorder.new(surface: "chat", chat_session: chat,
        provider: chat.effective_chat_provider, sidecar_mode: "bridge")
      tool_use_id = SecureRandom.uuid
      recorder.record_call(tool_name: call[:name], tool_use_id:, tool_input: call[:arguments])
      status, headers, body = yield
      text = read_body(body)
      result = response_result(text)
      recorder.record_result(tool_name: call[:name], tool_use_id:, content: result&.dig("content"),
        error: status.to_i >= 400 || result.nil? || result["isError"] == true)
      [ status, headers, [ text ] ]
    end

    def tool_call(request)
      return unless request.post?
      # Oversized bodies are the transport's to reject; never buffer them here.
      return if request.content_length.to_i > MCP::Server::Transports::StreamableHTTPTransport::DEFAULT_MAX_REQUEST_BYTES

      raw = request.body.read
      request.body.rewind
      payload = JSON.parse(raw)
      return unless payload.is_a?(Hash) && payload["method"] == "tools/call"

      params = payload["params"].to_h
      { name: params["name"].to_s, arguments: params["arguments"].to_h }
    rescue JSON::ParserError
      nil
    end

    def read_body(body)
      text = +""
      body.each { |chunk| text << chunk }
      text
    ensure
      body.close if body.respond_to?(:close)
    end

    def response_result(text)
      payload = JSON.parse(text)
      payload["result"] if payload.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def bearer_token(request)
      request.get_header("HTTP_AUTHORIZATION").to_s[/\ABearer\s+(\S+)\z/i, 1]
    end

    def bad_token_limited?(request)
      Rails.cache.read(bad_token_key(request)).to_i >= BAD_TOKEN_LIMIT
    end

    def record_bad_token(request)
      Rails.cache.increment(bad_token_key(request), 1, expires_in: BAD_TOKEN_WINDOW)
    end

    def bad_token_key(request) = [ "rate-limit", "mcp-bridge-bad-token", request.ip ].join(":")

    def unauthorized
      json(401, "unauthorized", I18n.t("mcp_bridge.unauthorized"), "WWW-Authenticate" => 'Bearer realm="syrus-mcp-bridge"')
    end

    def rate_limited = json(429, "rate_limited", I18n.t("api.base.rate_limited"))

    def json(status, code, message, headers = {})
      [ status, { "content-type" => "application/json" }.merge(headers), [ JSON.generate(error: { code:, message: }) ] ]
    end
  end
end
