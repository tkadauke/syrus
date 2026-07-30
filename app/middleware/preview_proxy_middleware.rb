require "net/http"

class PreviewProxyMiddleware
  HOP_BY_HOP_HEADERS = %w[
    connection keep-alive proxy-authenticate proxy-authorization
    te trailer transfer-encoding upgrade
  ].to_set.freeze

  HTTP_METHODS = {
    "GET"     => Net::HTTP::Get,
    "POST"    => Net::HTTP::Post,
    "PUT"     => Net::HTTP::Put,
    "PATCH"   => Net::HTTP::Patch,
    "DELETE"  => Net::HTTP::Delete,
    "HEAD"    => Net::HTTP::Head,
    "OPTIONS" => Net::HTTP::Options,
  }.freeze

  def initialize(app)
    @app = app
    @base_domain = ENV.fetch("SYRUS_PREVIEW_BASE_DOMAIN", "lvh.me")
    @host_pattern = /\Apreview-(\d+)\.#{Regexp.escape(@base_domain)}(?::\d+)?\z/
  end

  def call(env)
    host = env["HTTP_HOST"].to_s
    match = @host_pattern.match(host)
    return @app.call(env) unless match

    job_id = match[1].to_i
    preview_env = PreviewEnvironment.find_by(job_id: job_id, state: "running")
    return not_available_response unless preview_env

    preview_env.touch_activity!
    proxy(env, preview_env)
  rescue => e
    Rails.logger.error("PreviewProxyMiddleware: #{e.class}: #{e.message}")
    [502, { "Content-Type" => "text/html; charset=utf-8" }, ["<p>Proxy error.</p>"]]
  end

  private

  def proxy(env, preview_env)
    request = Rack::Request.new(env)
    target_host = preview_env.internal_host.presence || "127.0.0.1"
    target_port = preview_env.port
    path = request.path.presence || "/"
    query = request.query_string.presence

    uri = URI::HTTP.build(host: target_host, port: target_port, path: path, query: query)
    http_klass = HTTP_METHODS.fetch(request.request_method, Net::HTTP::Get)
    proxy_req = http_klass.new(uri.request_uri)

    copy_request_headers(env, proxy_req)
    proxy_req["Host"] = "#{target_host}:#{target_port}"

    if request.body
      body = request.body.read
      proxy_req.body = body unless body.empty?
      request.body.rewind rescue nil
    end

    Net::HTTP.start(target_host, target_port) do |http|
      proxy_resp = http.request(proxy_req)
      status = proxy_resp.code.to_i
      headers = {}
      proxy_resp.each_header do |name, value|
        headers[name] = value unless HOP_BY_HOP_HEADERS.include?(name.downcase)
      end
      [status, headers, [proxy_resp.body || ""]]
    end
  end

  def copy_request_headers(env, proxy_req)
    env.each do |key, value|
      next unless key.start_with?("HTTP_")
      header = key[5..].gsub("_", "-").downcase
      next if header == "host"
      proxy_req[header] = value
    end
    proxy_req["Content-Type"] = env["CONTENT_TYPE"] if env["CONTENT_TYPE"].present?
    proxy_req["Content-Length"] = env["CONTENT_LENGTH"] if env["CONTENT_LENGTH"].present?
  end

  def not_available_response
    body = <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Preview Not Available</title></head>
        <body>
          <p>Preview not available. Start it from the Syrus UI.</p>
        </body>
      </html>
    HTML
    [503, { "Content-Type" => "text/html; charset=utf-8" }, [body]]
  end
end
