require "mcp"

module SyrusBrowser
  # Spawns and owns a single @playwright/mcp stdio subprocess for the
  # lifetime of a workflow Run. One browser (and one MCP::Client connection
  # to it) is reused across every browser_* tool call within the Run, so a
  # multi-step flow (navigate, then click, then screenshot) sees the same
  # page Playwright left it in.
  #
  # `@playwright/mcp` is Microsoft's own MCP server for Playwright, baked
  # into the worker image (see Dockerfile's worker-deps stage) and bundled
  # here as a stdio subprocess rather than hand-rolled Playwright bindings.
  # `--isolated` gives each Run a throwaway browser profile; `--headless` is
  # required since the worker container has no display server. The command
  # is invoked via `npx` (present alongside Node for the claude-code/codex
  # CLIs) without a version pin so it resolves the copy already installed
  # globally in the image, offline. The executable path is explicit because
  # @playwright/mcp otherwise defaults to the branded Chrome channel in some
  # environments, while Syrus workers ship Playwright's bundled Chromium.
  class Session
    DEFAULT_COMMAND = "npx".freeze
    DEFAULT_EXECUTABLE_PATH = "/opt/syrus-browser/chromium".freeze

    def self.default_args
      %W[--yes @playwright/mcp --headless --isolated --executable-path #{browser_executable_path}]
    end

    def self.browser_executable_path
      ENV.fetch("SYRUS_BROWSER_EXECUTABLE_PATH", DEFAULT_EXECUTABLE_PATH)
    end

    def self.spawn(run_id, command: DEFAULT_COMMAND, args: default_args, env: nil)
      new(run_id, command: command, args: args, env: env)
    end

    def initialize(run_id, command: DEFAULT_COMMAND, args: self.class.default_args, env: nil)
      @run_id = run_id
      @transport = MCP::Client::Stdio.new(command: command, args: args, env: env)
      @client = MCP::Client.new(transport: @transport)
      @connected = false
      @mutex = Mutex.new
    end

    # Serialized: an agent turn can issue multiple tool_use blocks for the
    # same MCP server in one turn, and interleaved reads/writes on a single
    # stdio pipe pair are not safe to run concurrently from this side.
    def call_tool(name:, arguments:)
      @mutex.synchronize do
        connect!
        @client.call_tool(name: name, arguments: arguments)
      end
    end

    def close
      @mutex.synchronize { @transport.close }
    rescue StandardError
      nil
    end

    private

    def connect!
      return if @connected

      @client.connect(client_info: { name: "syrus-browser", version: SyrusBrowser::VERSION })
      @connected = true
    end
  end
end
