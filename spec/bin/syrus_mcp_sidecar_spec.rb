# frozen_string_literal: true

require "open3"
require "rails_helper"
require "socket"
require "timeout"

RSpec.describe "bin/syrus-mcp-sidecar" do
  let(:root) { Rails.root.to_s }
  let(:clean_env) do
    {
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH"),
      "TMPDIR" => ENV["TMPDIR"]
    }.compact
  end

  def read_http_request(socket)
    request_line = socket.gets
    headers = {}
    while (line = socket.gets)
      line = line.chomp
      break if line.empty?

      key, value = line.split(":", 2)
      headers[key.downcase] = value.to_s.strip
    end

    body = socket.read(headers.fetch("content-length", "0").to_i)
    { request_line: request_line, body: body }
  end

  def write_http_response(socket, status:, body:)
    reason = Rack::Utils::HTTP_STATUS_CODES.fetch(status)
    socket.write("HTTP/1.1 #{status} #{reason}\r\n")
    socket.write("Content-Type: application/json\r\n")
    socket.write("Content-Length: #{body.bytesize}\r\n")
    socket.write("Connection: close\r\n\r\n")
    socket.write(body)
  end

  def with_proxy_upstream(responses)
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    thread = Thread.new do
      responses.each do |response|
        socket = server.accept
        request = read_http_request(socket)
        requests << JSON.parse(request.fetch(:body))
        write_http_response(socket, **response)
        socket.close
      end
    end

    yield "http://127.0.0.1:#{server.addr[1]}/mcp", requests
  ensure
    server&.close
    thread&.kill
    thread&.join
  end

  def run_proxy(url:, input:)
    stdout = +""
    stderr = +""
    status = nil
    Timeout.timeout(5) do
      Open3.popen3(
        clean_env.merge("SYRUS_MCP_PROXY_URL" => url, "SYRUS_MCP_PROXY_INVOCATION_CONTEXT" => "proxy-token"),
        RbConfig.ruby,
        "bin/syrus-mcp-proxy",
        chdir: root,
        unsetenv_others: true
      ) do |stdin, out, err, wait_thread|
        stdin.write(input)
        stdin.close
        stdout = out.read
        stderr = err.read
        status = wait_thread.value
      end
    end
    [ stdout, stderr, status ]
  end

  it "does not log successful SystemExit shutdown as a startup failure" do
    Dir.mktmpdir do |dir|
      script = <<~RUBY
        require "fileutils"
        require_relative "config/environment"

        module SyrusSidecarBootstrap
          def self.prepare_bundle!(sidecar_env_key:)
          end

          def self.open_run_stderr!(run_id:, server_name:)
            log_dir = File.join(ENV.fetch("SYRUS_DATA_ROOT"), "mcp-sidecar-logs")
            FileUtils.mkdir_p(log_dir)
            $stderr.reopen(File.join(log_dir, "run-\#{run_id}.stderr.log"), "a")
            $stderr.sync = true
            warn "[syrus-mcp-sidecar] starting \#{server_name}"
          end
        end

        Mcp::Sidecar.singleton_class.define_method(:workflow) do |run_id:|
          Object.new.tap do |sidecar|
            sidecar.define_singleton_method(:run) { raise SystemExit.new(0) }
          end
        end

        ARGV.replace(["--run-id", "123"])
        sidecar_script = File.read("bin/syrus-mcp-sidecar")
          .sub(%(require_relative "../lib/syrus_sidecar_bootstrap"\\n), "")
        eval(sidecar_script, TOPLEVEL_BINDING, File.expand_path("bin/syrus-mcp-sidecar", Dir.pwd))
      RUBY

      _stdout, stderr, status = Open3.capture3(
        clean_env.merge("SYRUS_DATA_ROOT" => dir),
        RbConfig.ruby,
        "-e",
        script,
        chdir: root,
        unsetenv_others: true
      )

      expect(status).to be_success, stderr
      sidecar_stderr = File.read(File.join(dir, "mcp-sidecar-logs", "run-123.stderr.log"))
      expect(sidecar_stderr).to include("starting syrus-mcp-sidecar")
      expect(sidecar_stderr).not_to include("failed to start for run")
      expect(sidecar_stderr).not_to include("SystemExit")
    end
  end

  it "does not activate date before Bundler selects the application bundle" do
    script = <<~RUBY
      begin
        load "bin/syrus-mcp-sidecar"
      rescue SystemExit
      end

      abort "date activated before Bundler setup" if Gem.loaded_specs.key?("date")
      %w[BUNDLE_APP_CONFIG BUNDLE_USER_HOME BUNDLE_USER_CACHE BUNDLE_BIN_PATH RUBYOPT].each do |key|
        abort "\#{key} leaked into sidecar boot" if ENV.key?(key)
      end
    RUBY

    _stdout, stderr, status = Open3.capture3(
      clean_env.merge(
        "BUNDLE_APP_CONFIG" => "/workspace/.syrus/deps/bundle-config",
        "BUNDLE_USER_HOME" => "/workspace/.syrus/deps/bundle-home",
        "BUNDLE_USER_CACHE" => "/workspace/.syrus/deps/bundle-cache",
        "BUNDLE_BIN_PATH" => "/workspace/.syrus/deps/bundle/bin/bundle",
        "RUBYOPT" => "-W0"
      ),
      RbConfig.ruby,
      "-e",
      script,
      chdir: root,
      unsetenv_others: true
    )

    expect(status).to be_success, stderr
  end

  it "loads Octokit under the production sidecar bundle without the Faraday retry warning" do
    script = <<~RUBY
      require "octokit"

      handlers = Octokit::Default::MIDDLEWARE.handlers.map { |handler| handler.klass.name }
      abort "Octokit retry middleware missing" unless handlers.include?("Faraday::Retry::Middleware")
      Octokit::Client.new
    RUBY

    _stdout, stderr, status = Open3.capture3(
      clean_env.merge(
        "BUNDLE_GEMFILE" => File.join(root, "Gemfile"),
        "BUNDLE_PATH" => File.join(root, "vendor/bundle"),
        "BUNDLE_APP_CONFIG" => File.join(root, ".bundle"),
        "BUNDLE_WITHOUT" => "development:test"
      ),
      RbConfig.ruby,
      "-rbundler/setup",
      "-e",
      script,
      chdir: root,
      unsetenv_others: true
    )

    expect(status).to be_success, stderr
    expect(stderr).not_to include("To use retry middleware with Faraday v2.0+")
  end

  it "keeps the stdio proxy free of Rails boot secrets" do
    proxy = File.read("bin/syrus-mcp-proxy")

    expect(proxy).to include("X-Syrus-Invocation-Context")
    expect(proxy).not_to include("config/environment")
    expect(proxy).not_to include("RAILS_MASTER_KEY")
    expect(proxy).not_to include("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY")
    expect(proxy).not_to include("DATABASE_URL")
    expect(proxy).not_to include("S3_SECRET_ACCESS_KEY")
  end

  it "does not emit stdio frames for notification responses with blank bodies" do
    responses = [
      { status: 200, body: { jsonrpc: "2.0", id: 1, result: { protocolVersion: "2025-03-26" } }.to_json },
      { status: 202, body: "" },
      { status: 200, body: { jsonrpc: "2.0", id: 2, result: { tools: [] } }.to_json }
    ]
    input = [
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      { jsonrpc: "2.0", method: "notifications/initialized", params: {} },
      { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }
    ].map(&:to_json).join("\n") + "\n"

    with_proxy_upstream(responses) do |url, requests|
      stdout, stderr, status = run_proxy(url: url, input: input)

      expect(status).to be_success, stderr
      expect(stderr).to be_empty
      lines = stdout.lines.map(&:chomp)
      expect(lines).not_to include("")
      frames = lines.map { |line| JSON.parse(line) }
      expect(frames.map { |frame| frame.fetch("id") }).to eq([ 1, 2 ])
      expect(3.times.map { requests.pop.fetch("method") }).to eq([ "initialize", "notifications/initialized", "tools/list" ])
    end
  end

  it "emits one parseable JSON-RPC error frame when the proxy upstream is unreachable" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    input = { jsonrpc: "2.0", id: 7, method: "tools/list", params: {} }.to_json + "\n"

    stdout, stderr, status = run_proxy(url: "http://127.0.0.1:#{port}/mcp", input: input)

    expect(status).to be_success, stderr
    expect(stderr).to be_empty
    lines = stdout.lines.map(&:chomp)
    expect(lines.size).to eq(1)
    frame = JSON.parse(lines.first)
    expect(frame).to include("jsonrpc" => "2.0", "id" => 7)
    expect(frame.fetch("error")).to include("code" => -32_603)
  end
end
