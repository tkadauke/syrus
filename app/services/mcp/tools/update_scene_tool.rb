require "mcp"

module Mcp::Tools
  class UpdateSceneTool < MCP::Tool
    tool_name "update_scene"

    description "Replace the whiteboard scene. Use only when high-level tools cannot express the change."

    input_schema(
      properties: {
        elements: { type: "array", items: { type: "object" } },
        appState: { type: "object", description: "Optional Excalidraw appState to persist with the scene." },
        files: { type: "object", description: "Optional Excalidraw BinaryFiles map for image elements." }
      },
      required: %w[elements]
    )

    class << self
      def call(elements:, server_context:, appState: nil, files: nil)
        Canvas.validate_scene!(elements: elements, app_state: appState, files: files)

        args = { "elements" => elements, "appState" => appState, "files" => files }.compact
        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |current_elements, scene|
          current_elements.replace(Canvas.deep_dup_elements(elements))
          scene["appState"] = Canvas.deep_dup_scene(appState) if appState
          scene["files"] = Canvas.deep_dup_scene(files) if files
          { replaced: true }
        end

        Mcp::Tools.success(result)
      rescue Canvas::ElementLimitExceeded => e
        Mcp::Tools.tool_error(e.message)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
