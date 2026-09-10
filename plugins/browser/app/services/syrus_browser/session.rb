require "mcp"

module SyrusBrowser
  # Spawns and owns a single @playwright/mcp stdio subprocess for the
  # lifetime of one owning session -- a workflow Run (visual_review) or a
  # Coding Mode chat's RuntimeSession (see SessionContext). One browser (and
  # one MCP::Client connection to it) is reused across every browser_* tool
  # call for that owner, so a multi-step flow (navigate, then click, then
  # screenshot) sees the same page Playwright left it in.
  #
  # `@playwright/mcp` is Microsoft's own MCP server for Playwright, baked
  # into the worker image (see Dockerfile's worker-deps stage) and bundled
  # here as a stdio subprocess rather than hand-rolled Playwright bindings.
  # `--isolated` gives each Run a throwaway browser profile; `--headless` is
  # required since the worker container has no display server. The command
  # uses the globally installed `playwright-mcp` binary from the worker image,
  # rather than `npx @playwright/mcp`, so npm cannot silently resolve a newer
  # schema at runtime. The executable path is explicit because @playwright/mcp
  # otherwise defaults to the branded Chrome channel in some environments,
  # while Syrus workers ship Playwright's bundled Chromium.
  class Session
    DEFAULT_COMMAND = "playwright-mcp".freeze
    DEFAULT_EXECUTABLE_PATH = "/opt/syrus-browser/chromium".freeze
    CLEAR_BROWSER_STATE_SCRIPT = <<~JS.squish.freeze
      async () => {
        try { localStorage.clear(); } catch {}
        try { sessionStorage.clear(); } catch {}
        try {
          if ("caches" in window) {
            const names = await caches.keys();
            await Promise.all(names.map((name) => caches.delete(name)));
          }
        } catch {}
        try {
          if (navigator.serviceWorker) {
            const registrations = await navigator.serviceWorker.getRegistrations();
            await Promise.all(registrations.map((registration) => registration.unregister()));
          }
        } catch {}
        return true;
      }
    JS

    def self.default_args
      %W[--headless --isolated --block-service-workers --executable-path #{browser_executable_path}]
    end

    def self.browser_executable_path
      ENV.fetch("SYRUS_BROWSER_EXECUTABLE_PATH", DEFAULT_EXECUTABLE_PATH)
    end

    def self.spawn(session_key, command: DEFAULT_COMMAND, args: default_args, env: nil)
      new(session_key, command: command, args: args, env: default_env.merge(env.to_h))
    end

    def self.default_env
      {
        "PLAYWRIGHT_MCP_EXECUTABLE_PATH" => browser_executable_path,
        "PLAYWRIGHT_BROWSERS_PATH" => ENV.fetch("PLAYWRIGHT_BROWSERS_PATH", "/opt/ms-playwright")
      }
    end

    def initialize(session_key, command: DEFAULT_COMMAND, args: self.class.default_args, env: nil)
      @session_key = session_key
      @transport = MCP::Client::Stdio.new(command: command, args: args, env: env)
      @client = MCP::Client.new(transport: @transport)
      @connected = false
      @browser_state_cleared = false
      @mutex = Mutex.new
    end

    # Serialized: an agent turn can issue multiple tool_use blocks for the
    # same MCP server in one turn, and interleaved reads/writes on a single
    # stdio pipe pair are not safe to run concurrently from this side.
    def call_tool(name:, arguments:)
      @mutex.synchronize do
        connect!
        response = @client.call_tool(name: name, arguments: arguments)
        return response unless name == "browser_navigate" && successful_tool_response?(response)

        return response unless clear_browser_state_once!

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

      @client.connect(client_info: { name: "syrus-browser", version: Syrus::PluginApi.default_version })
      @connected = true
    end

    def clear_browser_state_once!
      return false if @browser_state_cleared

      @client.call_tool(
        name: "browser_evaluate",
        arguments: { "function" => CLEAR_BROWSER_STATE_SCRIPT }
      )
      true
    rescue StandardError => e
      Rails.logger.warn("[SyrusBrowser::Session] browser state reset failed for #{@session_key}: #{e.class}: #{e.message}")
      false
    ensure
      @browser_state_cleared = true
    end

    def successful_tool_response?(response)
      result = response.is_a?(Hash) ? response["result"] : nil
      !result.is_a?(Hash) || result["isError"] != true
    end
  end
end
