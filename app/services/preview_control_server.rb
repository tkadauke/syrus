require "puma"
require "json"

# Internal-only HTTP control surface for the `preview` service process.
#
# The web process does not share a filesystem with `preview` (they are
# separate Kubernetes Deployments), so it cannot read preview app logs off
# local disk. This server runs inside the `preview` process — where the
# preview workspace actually lives on disk — and answers log requests over
# HTTP instead. See PreviewLogClient for the web-process caller.
#
# Bound on a fixed port (SYRUS_PREVIEW_CONTROL_PORT), distinct from the
# per-environment app port range (SYRUS_PREVIEW_PORT_MIN/MAX = 20000-29999).
# Like the terminal relay, this is internal/private network only and must
# never be exposed through public ingress.
class PreviewControlServer
  DEFAULT_PORT = 4568
  PORT = Integer(ENV.fetch("SYRUS_PREVIEW_CONTROL_PORT", DEFAULT_PORT))
  HOST = "0.0.0.0"

  LOGS_PATH = %r{\A/environments/(\d+)/logs\z}

  def self.start(host: HOST, port: PORT)
    new(host: host, port: port).tap(&:start)
  end

  def initialize(host: HOST, port: PORT)
    @host = host
    @port = port
  end

  def start
    @server = Puma::Server.new(method(:call))
    @server.add_tcp_listener(@host, @port)
    @server.run(true, thread_name: "preview-control")
    Rails.logger.info("[PreviewControlServer] listening on #{@host}:#{@port}")
    self
  end

  def stop
    return unless @server

    @server.stop(true)
    Rails.logger.info("[PreviewControlServer] stopped")
  end

  def call(env)
    request = Rack::Request.new(env)
    return not_found unless request.get?

    match = LOGS_PATH.match(request.path)
    return not_found unless match

    logs_response(match[1].to_i, request.params["lines"])
  rescue StandardError => e
    Rails.logger.error("[PreviewControlServer] #{e.class}: #{e.message}")
    json_response(500, error: "internal_error")
  end

  private

  def logs_response(environment_id, lines)
    environment = with_connection { PreviewEnvironment.find_by(id: environment_id) }
    return not_found unless environment

    logs = PreviewLogReader.call(environment, lines: lines.presence || PreviewLogReader::DEFAULT_LINES)
    json_response(200, logs: logs.map { |log| { path: log.path, content: log.content, missing: log.missing } })
  end

  def not_found
    json_response(404, error: "not_found")
  end

  def json_response(status, payload)
    [ status, { "Content-Type" => "application/json" }, [ JSON.generate(payload) ] ]
  end

  def with_connection(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end
end
