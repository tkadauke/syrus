require "mcp"

module SyrusChatMcp
  class SaveCanvasTool < MCP::Tool
    tool_name "save_canvas"

    description "Save the current whiteboard scene as a named snapshot. Snapshots appear in the media tab and can be restored later with load_canvas."

    input_schema(
      properties: {
        name: { type: "string", description: "Optional operator-provided label for the snapshot." }
      }
    )

    class << self
      def call(server_context:, name: nil)
        chat_session = server_context.fetch(:chat_session)
        scene = Canvas.read(chat_session)

        return SyrusChatMcp.success(saved: false, reason: "canvas is empty") if scene.fetch("elements").empty?

        snapshot = WhiteboardSnapshot.create_from_scene!(
          chat_session: chat_session,
          scene: scene,
          kind: "manual",
          name: name
        )

        SyrusChatMcp.success(
          saved: true,
          snapshot_id: snapshot.id,
          name: snapshot.name,
          element_count: snapshot.element_count
        )
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.message)
      end
    end
  end
end
