require "mcp"

module SyrusBrowser
  class CloseTool < BrowserTool
    tool_name "browser_close"

    description "Close the headless browser and free its resources. Optional — the browser is " \
                "also closed automatically when the workflow step ends."

    input_schema(type: "object", properties: {}, required: [])

    class << self
      def call(server_context:, **_params)
        context = SessionContext.resolve(server_context)
        SessionRegistry.kill(context.session_key)
        ok(closed: true)
      rescue SessionContext::NoActiveSessionError => e
        error(e.message)
      rescue StandardError => e
        error("#{e.class}: #{e.message}")
      end
    end
  end
end
