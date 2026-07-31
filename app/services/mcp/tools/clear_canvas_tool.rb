require "mcp"

module Mcp::Tools
  class ClearCanvasTool < MCP::Tool
    tool_name "clear_canvas"

    description "Remove all elements from the whiteboard scene. The current scene is automatically saved as a snapshot before clearing and can be restored from the media tab or via load_canvas."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        scene = Canvas.read(chat_session)
        snapshot = if scene.fetch("elements").any?
          WhiteboardSnapshot.create_from_scene!(
            chat_session: chat_session,
            scene: scene,
            kind: "auto_clear"
          )
        end

        result = Canvas.mutate(chat_session, tool_name, {}) do |elements|
          elements.clear
          { cleared: true, snapshot_id: snapshot&.id }
        end

        Mcp::Tools.success(result)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
