require "mcp"
require "json"

module SyrusBrowser
  # Granular browser-control MCP tools for the visual_review agent (and any
  # other agentic step): navigate, click, fill, snapshot, screenshot,
  # wait_for. Deliberately NOT one opaque "run test suite" tool — the agent
  # improvises its own test plan against the running preview.
  #
  # Each call is proxied to a per-Run @playwright/mcp subprocess (see
  # Session / SessionRegistry) — Microsoft's own MCP server for Playwright,
  # bundled as a stdio subprocess rather than hand-rolled. Our tool names,
  # descriptions, and input schemas are our own stable, Ruby-idiomatic
  # surface; ARGUMENT_KEY_MAPS translates them to the upstream server's
  # wire format so that surface can stay stable even if upstream's argument
  # naming changes.
  #
  # browser_navigate is hard-restricted to loopback URLs (LoopbackGuard) —
  # an LLM driving a real browser is an SSRF/exfiltration surface if it can
  # reach arbitrary URLs, so this is enforced here, in the handler, not just
  # in the agent's prompt.
  class McpToolSet
    NAVIGATE   = "browser_navigate"
    CLICK      = "browser_click"
    FILL       = "browser_fill"
    SNAPSHOT   = "browser_snapshot"
    SCREENSHOT = "browser_screenshot"
    WAIT_FOR   = "browser_wait_for"
    CLOSE      = "browser_close"

    # Our tool name => underlying @playwright/mcp tool name. "fill" maps to
    # Playwright MCP's "browser_type" (type text into a targeted element);
    # "screenshot" maps to "browser_take_screenshot". browser_close is
    # handled locally (kills the session) rather than proxied.
    UPSTREAM_TOOL_NAMES = {
      NAVIGATE   => "browser_navigate",
      CLICK      => "browser_click",
      FILL       => "browser_type",
      SNAPSHOT   => "browser_snapshot",
      SCREENSHOT => "browser_take_screenshot",
      WAIT_FOR   => "browser_wait_for"
    }.freeze

    # Our (snake_case) argument name => upstream (camelCase, per Playwright
    # MCP's own TypeScript schema) argument name, per tool.
    ARGUMENT_KEY_MAPS = {
      NAVIGATE   => { url: "url" },
      CLICK      => { element: "element", ref: "ref" },
      FILL       => { element: "element", ref: "ref", text: "text" },
      SNAPSHOT   => {},
      SCREENSHOT => { element: "element", ref: "ref" },
      WAIT_FOR   => { text: "text", text_gone: "textGone", time: "time" }
    }.freeze

    TOOL_DEFS = [
      {
        name: NAVIGATE,
        description: "Navigate the headless browser to a URL. Restricted to the worker's own " \
                      "loopback preview (127.0.0.1/localhost, as started by start_preview) — any " \
                      "other host is rejected before the browser is touched.",
        input_schema: {
          type: "object",
          properties: {
            url: { type: "string", description: "URL to navigate to, e.g. http://127.0.0.1:3001/dashboard" }
          },
          required: ["url"]
        }
      },
      {
        name: SNAPSHOT,
        description: "Capture an accessibility-tree snapshot of the current page. Each interactive " \
                      "element gets a stable `ref` you can pass to browser_click / browser_fill to " \
                      "target it precisely, instead of guessing CSS selectors. Call this after " \
                      "navigating, and again after any action that changes the page.",
        input_schema: { type: "object", properties: {}, required: [] }
      },
      {
        name: CLICK,
        description: "Click an element on the current page, targeted by the `ref` from a prior " \
                      "browser_snapshot call.",
        input_schema: {
          type: "object",
          properties: {
            element: { type: "string", description: "Human-readable description of the element, for logging." },
            ref:     { type: "string", description: "Element ref returned by browser_snapshot." }
          },
          required: %w[element ref]
        }
      },
      {
        name: FILL,
        description: "Type text into a form field, targeted by the `ref` from a prior browser_snapshot call.",
        input_schema: {
          type: "object",
          properties: {
            element: { type: "string", description: "Human-readable description of the element, for logging." },
            ref:     { type: "string", description: "Element ref returned by browser_snapshot." },
            text:    { type: "string", description: "Text to type into the field." }
          },
          required: %w[element ref text]
        }
      },
      {
        name: SCREENSHOT,
        description: "Take a screenshot of the current page (or a single element, if `ref` is given). " \
                      "Returns image content the agent can inspect directly.",
        input_schema: {
          type: "object",
          properties: {
            element: { type: "string", description: "Human-readable description of the element to screenshot, if any." },
            ref:     { type: "string", description: "Element ref returned by browser_snapshot, if screenshotting a single element." }
          },
          required: []
        }
      },
      {
        name: WAIT_FOR,
        description: "Wait for text to appear or disappear on the page, or for a fixed number of seconds.",
        input_schema: {
          type: "object",
          properties: {
            text:      { type: "string", description: "Wait until this text appears on the page." },
            text_gone: { type: "string", description: "Wait until this text is no longer on the page." },
            time:      { type: "number", description: "Wait this many seconds instead of watching for text." }
          },
          required: []
        }
      },
      {
        name: CLOSE,
        description: "Close the headless browser and free its resources. Optional — the browser is " \
                      "also closed automatically when the workflow step ends.",
        input_schema: { type: "object", properties: {}, required: [] }
      }
    ].freeze

    def self.available_for?(_repository)
      true
    end

    def self.tool_definitions
      TOOL_DEFS
    end

    def handle(tool_name, params, server_context)
      params = normalize_params(params)

      case tool_name
      when NAVIGATE                    then handle_navigate(params, server_context)
      when CLOSE                       then handle_close(server_context)
      when *UPSTREAM_TOOL_NAMES.keys    then handle_passthrough(tool_name, params, server_context)
      else
        error_response("Unknown browser tool: #{tool_name.inspect}")
      end
    rescue MCP::Client::ServerError => e
      error_response("browser tool #{tool_name} failed: #{e.message}")
    rescue StandardError => e
      error_response("#{e.class}: #{e.message}")
    end

    private

    def handle_navigate(params, server_context)
      url = params[:url]
      return error_response("url is required") if url.blank?

      unless LoopbackGuard.allowed?(url)
        return error_response(
          "Navigation to #{url.inspect} was blocked: the browser tool set can only reach the " \
          "worker's own loopback preview (http://127.0.0.1:<port> or http://localhost:<port>)."
        )
      end

      handle_passthrough(NAVIGATE, params, server_context)
    end

    def handle_close(server_context)
      run = Mcp::Tools.run_from_context(server_context)
      SessionRegistry.kill(run.id)
      ok_response({ closed: true })
    end

    def handle_passthrough(tool_name, params, server_context)
      run = Mcp::Tools.run_from_context(server_context)
      session = SessionRegistry.fetch(run.id)
      response = session.call_tool(name: UPSTREAM_TOOL_NAMES.fetch(tool_name), arguments: upstream_arguments(tool_name, params))
      translate(response)
    end

    def upstream_arguments(tool_name, params)
      ARGUMENT_KEY_MAPS.fetch(tool_name, {}).each_with_object({}) do |(our_key, upstream_key), arguments|
        arguments[upstream_key] = params[our_key] if params.key?(our_key)
      end
    end

    def normalize_params(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end

    def translate(response)
      result = response.is_a?(Hash) ? response["result"] : nil
      content = result.is_a?(Hash) ? Array(result["content"]) : []
      content = content.map { |block| block.is_a?(Hash) ? block.transform_keys(&:to_sym) : block }
      error = result.is_a?(Hash) && result["isError"] == true
      MCP::Tool::Response.new(content.presence || [{ type: "text", text: "" }], error: error)
    end

    def ok_response(data)
      MCP::Tool::Response.new([{ type: "text", text: JSON.generate(data) }])
    end

    def error_response(msg)
      MCP::Tool::Response.new([{ type: "text", text: "Error: #{msg}" }], error: true)
    end
  end
end
