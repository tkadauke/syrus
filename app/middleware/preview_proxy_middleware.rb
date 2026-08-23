require "net/http"

class PreviewProxyMiddleware
  PREVIEW_CSP = [
    "default-src 'self' http: https: data: blob:",
    "script-src 'self' 'unsafe-inline' 'unsafe-eval' http: https: data: blob:",
    "style-src 'self' 'unsafe-inline' http: https:",
    "img-src 'self' http: https: data: blob:",
    "font-src 'self' http: https: data:",
    "connect-src 'self' http: https: data: blob: ws: wss:",
    "frame-src 'self' http: https: data: blob:",
    "child-src 'self' http: https: data: blob:",
    "worker-src 'self' blob:"
  ].join("; ").freeze

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
    proxy_req["Host"] = "localhost:#{target_port}"
    proxy_req["X-Forwarded-Host"] = "localhost:#{target_port}"
    proxy_req["X-Forwarded-Proto"] = "http"
    proxy_req["X-Syrus-Preview-Host"] = request.host_with_port
    proxy_req["X-Syrus-Preview-Proto"] = request.scheme
    normalize_browser_origin_headers!(request, proxy_req, target_port)

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
      body = rewrite_browser_localhost_origins(proxy_resp.body || "", headers)
      apply_preview_headers!(headers)
      [status, headers, [body]]
    end
  end

  def rewrite_browser_localhost_origins(body, headers)
    return body unless html_response?(headers)

    rewritten = body.gsub(%r{https?://(?:localhost|127\.0\.0\.1):\d+}, "")
    return body if rewritten == body

    delete_header!(headers, "Content-Length")
    delete_header!(headers, "ETag")
    rewritten
  end

  def html_response?(headers)
    content_type = headers["content-type"] || headers["Content-Type"]
    content_type.to_s.include?("text/html")
  end

  def apply_preview_headers!(headers)
    delete_header!(headers, "Content-Security-Policy")
    delete_header!(headers, "Content-Security-Policy-Report-Only")
    delete_header!(headers, "X-Frame-Options")
    delete_header!(headers, "Permissions-Policy")
    headers["Content-Security-Policy"] = PREVIEW_CSP
  end

  def delete_header!(headers, name)
    key = headers.keys.find { |candidate| candidate.casecmp?(name) }
    headers.delete(key) if key
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

  def normalize_browser_origin_headers!(request, proxy_req, target_port)
    internal_origin = "http://localhost:#{target_port}"
    origin = proxy_req["Origin"].to_s
    proxy_req["Origin"] = internal_origin if preview_origin?(origin, request)

    referer = proxy_req["Referer"].to_s
    if preview_origin?(referer, request)
      uri = URI.parse(referer)
      proxy_req["Referer"] = "#{internal_origin}#{uri.request_uri}"
    end
  rescue URI::InvalidURIError
    nil
  end

  def preview_origin?(value, request)
    return false if value.blank?

    uri = URI.parse(value)
    uri.host == request.host
  rescue URI::InvalidURIError
    false
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
