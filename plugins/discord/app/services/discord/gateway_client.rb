require "socket"
require "openssl"
require "uri"
require "json"
require "websocket/driver"

module Discord
  # Bot-initiated outbound WebSocket connection to Discord's Gateway (the
  # inbound half of the Discord integration -- no inbound HTTPS callback is
  # ever opened, matching Syrus's no-inbound-webhook design). One #run call
  # owns exactly one Gateway session: it connects, IDENTIFYs (or RESUMEs when
  # a prior session in this same #run is known), answers Gateway HEARTBEATs
  # on the server-provided interval, and dispatches every DISPATCH payload to
  # the block. A dropped connection is retried in place with RESUME up to
  # MAX_RECONNECT_ATTEMPTS (with backoff); beyond that, or when no session has
  # ever been established, #run simply returns so the caller
  # (Discord::GatewayConnectionJob) can reconnect from scratch on its next
  # poll cycle.
  class GatewayClient
    GATEWAY_VERSION = 10
    DEFAULT_URL = "wss://gateway.discord.gg"

    OP_DISPATCH        = 0
    OP_HEARTBEAT       = 1
    OP_IDENTIFY        = 2
    OP_RESUME          = 6
    OP_RECONNECT       = 7
    OP_INVALID_SESSION = 9
    OP_HELLO           = 10
    OP_HEARTBEAT_ACK   = 11

    # DIRECT_MESSAGES | MESSAGE_CONTENT -- the minimum needed to read DM text.
    INTENTS = (1 << 12) | (1 << 15)

    MAX_RECONNECT_ATTEMPTS = 5
    BACKOFF_BASE_SECONDS = 2

    def initialize(token:, url: DEFAULT_URL)
      @token = token
      @url = url
      @sequence = nil
      @session_id = nil
      @resume_url = nil
      @write_mutex = Mutex.new
    end

    # Connects and blocks dispatching Gateway DISPATCH payloads (the full
    # `{ "t" => ..., "d" => ... }` hash) to `handler` until the session ends.
    # Returns (does not raise) once retries are exhausted or the connection
    # closes for a non-resumable reason.
    def run(&handler)
      @handler = handler
      attempts = 0

      loop do
        @should_reconnect = false

        begin
          connect_and_pump
        rescue => e
          Rails.logger.error("Discord::GatewayClient: connection error: #{e.message}")
          @should_reconnect = @session_id.present?
        end

        break unless @should_reconnect

        attempts += 1
        break if attempts > MAX_RECONNECT_ATTEMPTS

        sleep(BACKOFF_BASE_SECONDS * attempts) unless Rails.env.test?
      end
    ensure
      stop_heartbeat
    end

    private

    def connect_and_pump
      uri = build_uri(@session_id ? (@resume_url || @url) : @url)
      @socket = open_socket(uri)
      @driver = ::WebSocket::Driver.client(SocketIO.new(@socket, uri.to_s))
      @closed = false

      @driver.on(:message) { |event| handle_frame(event.data) }
      @driver.on(:close) { @closed = true }
      @driver.on(:error) { |event| Rails.logger.error("Discord::GatewayClient: #{event.message}") }

      @driver.start
      pump until @closed
    ensure
      stop_heartbeat
      begin
        @socket&.close
      rescue IOError
        nil
      end
    end

    def pump
      data = @socket.readpartial(4096)
      @driver.parse(data)
    rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
      @closed = true
      @should_reconnect = @session_id.present?
    end

    def build_uri(base)
      URI("#{base}?v=#{GATEWAY_VERSION}&encoding=json")
    end

    def open_socket(uri)
      tcp = TCPSocket.new(uri.host, uri.port)
      context = OpenSSL::SSL::SSLContext.new
      context.set_params
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
      ssl.hostname = uri.host
      ssl.sync_close = true
      ssl.connect
      ssl
    end

    def handle_frame(raw)
      payload = JSON.parse(raw)
      @sequence = payload["s"] if payload["s"]

      case payload["op"]
      when OP_HELLO
        start_heartbeat(payload.dig("d", "heartbeat_interval"))
        @session_id ? send_resume : send_identify
      when OP_HEARTBEAT
        send_heartbeat
      when OP_RECONNECT
        @should_reconnect = true
        @driver.close
      when OP_INVALID_SESSION
        @session_id = nil unless payload["d"] == true
        @should_reconnect = true
        @driver.close
      when OP_DISPATCH
        handle_dispatch(payload)
      end
    end

    def handle_dispatch(payload)
      if payload["t"] == "READY"
        @session_id = payload.dig("d", "session_id")
        @resume_url = payload.dig("d", "resume_gateway_url")
      end

      @handler&.call(payload)
    end

    def start_heartbeat(interval_ms)
      return unless interval_ms

      stop_heartbeat
      @heartbeat_thread = Thread.new do
        loop do
          sleep(interval_ms / 1000.0)
          send_heartbeat
        end
      end
    end

    def stop_heartbeat
      @heartbeat_thread&.kill
      @heartbeat_thread = nil
    end

    def send_heartbeat
      send_payload(op: OP_HEARTBEAT, d: @sequence)
    end

    def send_identify
      send_payload(
        op: OP_IDENTIFY,
        d: {
          token: @token,
          intents: INTENTS,
          properties: { "os" => "linux", "browser" => "syrus", "device" => "syrus" }
        }
      )
    end

    def send_resume
      send_payload(op: OP_RESUME, d: { token: @token, session_id: @session_id, seq: @sequence })
    end

    def send_payload(payload)
      @write_mutex.synchronize { @driver.text(JSON.generate(payload)) }
    end

    # Minimal transport shim: websocket-driver writes the handshake request
    # and every outbound frame through #write, and reads `url` once (client
    # mode) to build the handshake request line.
    class SocketIO
      attr_reader :url

      def initialize(socket, url)
        @socket = socket
        @url = url
      end

      def write(data)
        @socket.write(data)
      end
    end
  end
end
