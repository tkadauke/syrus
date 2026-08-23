require "mcp"

module SyrusBrowser
  class CloseTool < BrowserTool
    tool_name "browser_close"

    description "Close the headless browser and free its resources. Optional — the browser is " \
                "also closed automatically when the workflow step ends."

    input_schema(type: "object", properties: {}, required: [])

    class << self
      def call(server_context:, **_params)
        run = Mcp::Tools.run_from_context(server_context)
        SessionRegistry.kill(run.id)
        ok(closed: true)
      rescue StandardError => e
        error("#{e.class}: #{e.message}")
      end
    end
  end
end
