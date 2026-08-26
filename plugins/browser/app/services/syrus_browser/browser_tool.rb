require "mcp"
require "json"

module SyrusBrowser
  # Base class for granular browser-control MCP tools (see McpToolSet).
  # Most tools are thin proxies to the per-Run @playwright/mcp subprocess:
  # a subclass declares `proxies upstream_tool_name, our_key => upstream_key`
  # and inherits .call, which forwards the request to the Run's browser
  # Session and translates the response back into our own tool-name/argument
  # surface. browser_navigate and browser_close override .call for their own
  # local behavior (loopback guard / session teardown) but still reuse the
  # shared ok/error helpers here.
  class BrowserTool < MCP::Tool
    class << self
      attr_accessor :upstream_tool_name, :argument_key_map

      def proxies(upstream_tool_name, argument_key_map = {})
        self.upstream_tool_name = upstream_tool_name
        self.argument_key_map = argument_key_map
      end

      def call(server_context:, **params)
        missing = missing_required_arguments(params)
        return error(missing_arguments_message(missing)) if missing.any?

        run = Mcp::Tools.run_from_context(server_context)
        session = SessionRegistry.fetch(run.id)
        response = session.call_tool(name: upstream_tool_name, arguments: upstream_arguments(params))
        translate(response)
      rescue MCP::Client::ServerError => e
        error("browser tool #{tool_name} failed: #{e.message}")
      rescue StandardError => e
        error("#{e.class}: #{e.message}")
      end

      def ok(data)
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(data) } ])
      end

      def error(message)
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{message}" } ], error: true)
      end

      private

      def missing_required_arguments(params)
        required = Array(input_schema_value.to_h.dig(:required))
        required.select do |key|
          value = params[key.to_sym]
          value.nil? || (value.respond_to?(:blank?) ? value.blank? : value.to_s.empty?)
        end
      end

      def missing_arguments_message(keys)
        "browser tool #{tool_name} requires #{keys.join(", ")}. " \
          "Call browser_snapshot first, then pass the exact element/ref pair from the snapshot; " \
          "do not invent refs or pass undefined targets."
      end

      def upstream_arguments(params)
        argument_key_map.each_with_object({}) do |(our_key, upstream_key), arguments|
          arguments[upstream_key] = params[our_key] if params.key?(our_key)
        end
      end

      def translate(response)
        result = response.is_a?(Hash) ? response["result"] : nil
        content = result.is_a?(Hash) ? Array(result["content"]) : []
        content = content.map { |block| block.is_a?(Hash) ? block.transform_keys(&:to_sym) : block }
        err = result.is_a?(Hash) && result["isError"] == true
        MCP::Tool::Response.new(content.presence || [ { type: "text", text: "" } ], error: err)
      end
    end
  end
end
