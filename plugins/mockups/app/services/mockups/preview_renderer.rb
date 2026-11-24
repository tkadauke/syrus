require "socket"
require "uri"

module Mockups
  # Renders a preview panel's *unpublished* scratch directory to a PNG for the
  # planning agent, without creating a PreviewPanelVersion or touching the
  # panel. Reuses the Browser plugin's Playwright session instead of owning a
  # screenshot engine.
  #
  # The scratch directory is served by a throwaway loopback-only HTTP server
  # bound to 127.0.0.1 on an ephemeral port. Every request is resolved through
  # ScratchDirectory (the same path jail and symlink rejection write/edit use),
  # so the page can only read that panel's own files, and the browser only ever
  # navigates to a loopback URL -- the same boundary SyrusBrowser::LoopbackGuard
  # enforces for every other browser tool. Responses carry the preview-panel
  # CSP so the page sees the same sandbox it will have once published.
  #
  # A dedicated one-shot stdio Playwright session is used (never the chat's
  # Coding Mode session, and never the Plugin Runtime service, which could not
  # reach this host's loopback), and is always closed afterwards.
  class PreviewRenderer
    class Unavailable < StandardError; end
    class InvalidRequest < StandardError; end

    VIEWPORT_PRESETS = {
      "desktop" => { width: 1280, height: 800 },
      "tablet" => { width: 768, height: 1024 },
      "mobile" => { width: 393, height: 852 }
    }.freeze
    DEFAULT_PRESET = "desktop".freeze
    MIN_DIMENSION = 200
    MAX_WIDTH = 2560
    MAX_HEIGHT = 4000
    MAX_WAIT_MS = 10_000
    REQUEST_TIMEOUT = 5

    Result = Struct.new(:image_data, :mime_type, :viewport, :preset, :full_page, :wait_ms, :entry_file, keyword_init: true)

    class << self
      # Test seam: swap in a fake factory so specs never spawn Playwright.
      attr_writer :session_factory

      def session_factory
        @session_factory ||= lambda do |key|
          session_class = "SyrusBrowser::Session".safe_constantize
          raise Unavailable, "the Browser plugin is not enabled, so previews cannot be rendered" unless session_class

          session_class.spawn_stdio(key)
        end
      end

      def reset!
        @session_factory = nil
      end
    end

    def initialize(scratch:, panel_id:, entry_file:, preset: nil, width: nil, height: nil, full_page: false, wait_ms: nil)
      @scratch = scratch
      @panel_id = panel_id
      @entry_file = entry_file.to_s
      @full_page = full_page ? true : false
      @preset, @viewport = resolve_viewport(preset, width, height)
      @wait_ms = resolve_wait(wait_ms)
    end

    def render
      path = @scratch.resolve(@entry_file)
      raise InvalidRequest, "entry_file #{@entry_file.inspect} was not found in the scratch directory" unless path.file?

      server = ScratchServer.new(@scratch)
      session = self.class.session_factory.call("mockup_render:#{@panel_id}:#{SecureRandom.hex(4)}")
      begin
        url = server.url_for(@entry_file)
        raise Unavailable, "refusing to navigate to non-loopback URL #{url}" if loopback_guard && !loopback_guard.allowed?(url)

        call(session, "browser_resize", "width" => @viewport[:width], "height" => @viewport[:height])
        call(session, "browser_navigate", "url" => url)
        call(session, "browser_wait_for", "time" => @wait_ms / 1000.0) if @wait_ms.positive?
        response = call(session, "browser_take_screenshot", "type" => "png", "fullPage" => @full_page)
        image = Array(response.dig("result", "content")).find { |block| block["type"] == "image" && block["data"].present? }
        raise Unavailable, "the browser did not return a screenshot" unless image

        Result.new(image_data: image["data"], mime_type: image["mimeType"].presence || "image/png",
                   viewport: @viewport, preset: @preset, full_page: @full_page, wait_ms: @wait_ms,
                   entry_file: @entry_file)
      ensure
        session&.close
        server.stop
      end
    end

    private

    def loopback_guard = "SyrusBrowser::LoopbackGuard".safe_constantize

    def call(session, name, arguments)
      response = session.call_tool(name: name, arguments: arguments)
      if response.is_a?(Hash) && response.dig("result", "isError") == true
        text = Array(response.dig("result", "content")).filter_map { |block| block["text"] }.join(" ").truncate(300)
        raise Unavailable, "#{name} failed: #{text}"
      end
      response
    end

    def resolve_viewport(preset, width, height)
      if width.present? || height.present?
        raise InvalidRequest, "width and height must be given together" if width.blank? || height.blank?

        w = bounded_integer("width", width, MIN_DIMENSION, MAX_WIDTH)
        h = bounded_integer("height", height, MIN_DIMENSION, MAX_HEIGHT)
        return [ nil, { width: w, height: h } ]
      end

      name = preset.presence || DEFAULT_PRESET
      viewport = VIEWPORT_PRESETS[name.to_s]
      raise InvalidRequest, "unknown viewport #{name.inspect}; use one of #{VIEWPORT_PRESETS.keys.join(', ')} or explicit width and height" unless viewport

      [ name.to_s, viewport ]
    end

    def resolve_wait(value)
      return 0 if value.blank?

      bounded_integer("wait_ms", value, 0, MAX_WAIT_MS)
    end

    def bounded_integer(label, value, min, max)
      number = Integer(value, exception: false)
      raise InvalidRequest, "#{label} must be an integer between #{min} and #{max}" unless number && number.between?(min, max)

      number
    end

    # Minimal GET/HEAD-only file server on 127.0.0.1. Anything the scratch
    # directory's own jail refuses (traversal, symlinks, missing files) is a 404.
    class ScratchServer
      def initialize(scratch)
        @scratch = scratch
        @server = TCPServer.new("127.0.0.1", 0)
        @threads = []
        @acceptor = Thread.new { accept_loop }
      end

      def url_for(relative_path)
        "http://127.0.0.1:#{@server.addr[1]}/#{relative_path.to_s.sub(%r{\A/+}, '').split('/').map { |part| URI.encode_www_form_component(part).gsub('+', '%20') }.join('/')}"
      end

      def stop
        @server.close unless @server.closed?
        @acceptor.kill
        @threads.each(&:kill)
      end

      private

      def accept_loop
        loop do
          client = @server.accept
          @threads << Thread.new(client) { |socket| serve(socket) }
        end
      rescue IOError, Errno::EBADF
        nil
      end

      def serve(socket)
        request_line = Timeout.timeout(REQUEST_TIMEOUT) do
          line = socket.gets.to_s
          while (header = socket.gets) && header != "\r\n"; end
          line
        end
        method, target, = request_line.split(" ")
        return respond(socket, 405, "text/plain", "method not allowed") unless %w[GET HEAD].include?(method)

        relative = URI.decode_www_form_component(target.to_s.sub(/[?#].*\z/, "").sub(%r{\A/}, "").gsub("+", "%2B"))
        path = @scratch.resolve(relative)
        return respond(socket, 404, "text/plain", "not found") unless path.file?

        respond(socket, 200, Marcel::MimeType.for(name: path.to_s), File.binread(path), head: method == "HEAD")
      rescue ScratchDirectory::InvalidPath
        respond(socket, 404, "text/plain", "not found")
      rescue StandardError
        nil
      ensure
        socket.close unless socket.closed?
      end

      def respond(socket, status, content_type, body, head: false)
        reason = { 200 => "OK", 404 => "Not Found", 405 => "Method Not Allowed" }.fetch(status)
        socket.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: #{content_type}\r\n" \
                     "Content-Length: #{body.bytesize}\r\nContent-Security-Policy: #{csp}\r\n" \
                     "Cache-Control: no-store\r\nConnection: close\r\n\r\n")
        socket.write(body) unless head
      end

      def csp
        "PreviewProxyMiddleware::PREVIEW_CSP".safe_constantize.to_s
      end
    end
  end
end
