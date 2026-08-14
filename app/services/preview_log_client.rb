require "net/http"

# Fetches preview app logs from the `preview` service's internal control
# endpoint (PreviewControlServer) instead of reading local disk — the web
# process does not share a filesystem with `preview`. Used by
# Api::V1::App::JobPreviewController#logs.
class PreviewLogClient
  class Unavailable < StandardError; end

  OPEN_TIMEOUT_SECONDS = 2
  READ_TIMEOUT_SECONDS = 5

  def self.call(preview_environment, lines: PreviewLogReader::DEFAULT_LINES)
    new(preview_environment, lines: lines).call
  end

  def initialize(preview_environment, lines:)
    @preview_environment = preview_environment
    @lines = lines
  end

  def call
    host = @preview_environment.internal_host
    raise Unavailable, "preview environment has no internal host recorded" if host.blank?

    response = fetch(host)
    raise Unavailable, "preview control endpoint returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(response.body)
    Array(parsed["logs"]).map do |log|
      PreviewLogReader::Log.new(path: log["path"], content: log["content"], missing: log["missing"])
    end
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError => e
    raise Unavailable, e.message
  end

  private

  def fetch(host)
    uri = URI::HTTP.build(
      host: host,
      port: PreviewControlServer::PORT,
      path: "/environments/#{@preview_environment.id}/logs",
      query: "lines=#{@lines}"
    )

    Net::HTTP.start(uri.host, uri.port, open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS) do |http|
      http.get(uri.request_uri)
    end
  end
end
