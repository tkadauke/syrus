require "mcp"

module Mcp::Tools
  class MoveElementTool < MCP::Tool
    tool_name "move_element"

    description "Move one whiteboard element to an absolute x/y position."

    input_schema(
      properties: {
        id: { type: "string" },
        x: { type: "number" },
        y: { type: "number" }
      },
      required: %w[id x y]
    )

    class << self
      def call(id:, x:, y:, server_context:)
        id = id.to_s
        return Mcp::Tools.invalid("id is required") if id.empty?

        args = {
          "id" => id,
          "x" => Canvas.number(x, "x"),
          "y" => Canvas.number(y, "y")
        }

        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          element = Canvas.find_element(elements, id)
          element["x"] = args.fetch("x")
          element["y"] = args.fetch("y")
          element["version"] = element.fetch("version", 0).to_i + 1
          element["updated"] = (Time.current.to_f * 1000).to_i
          Canvas.recalibrate_bound_arrows!(elements)
          { id: id }
        end

        Mcp::Tools.success(result)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
