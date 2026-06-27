require "mcp"

module SyrusChatMcp
  class LoadCanvasTool < MCP::Tool
    tool_name "load_canvas"

    description "Load a previously saved canvas snapshot back onto the whiteboard. In merge mode (default), the snapshot's elements are appended to the current canvas with fresh IDs. In replace mode, the current canvas is auto-saved first, then replaced with the snapshot."

    input_schema(
      properties: {
        snapshot_id: { type: "integer", description: "ID of the WhiteboardSnapshot to load." },
        mode: { type: "string", enum: %w[merge replace], description: "merge appends snapshot elements with fresh IDs; replace swaps the whole canvas after auto-saving the current scene." }
      },
      required: %w[snapshot_id]
    )

    class << self
      def call(snapshot_id:, server_context:, mode: "merge")
        chat_session = server_context.fetch(:chat_session)
        snapshot = chat_session.whiteboard_snapshots.find(snapshot_id)
        snapshot_scene = Whiteboard.normalize_scene!(snapshot.scene_json)
        mode = mode.to_s.presence || "merge"

        return SyrusChatMcp.invalid("mode must be merge or replace") unless %w[merge replace].include?(mode)

        result = if mode == "replace"
          replace_canvas(chat_session, snapshot_scene)
        else
          merge_canvas(chat_session, snapshot_scene)
        end

        SyrusChatMcp.success(result.merge(snapshot_id: snapshot.id, mode: mode))
      rescue Canvas::ElementLimitExceeded => e
        SyrusChatMcp.tool_error(e.message)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.message)
      end

      private

      def replace_canvas(chat_session, snapshot_scene)
        current_scene = Canvas.read(chat_session)
        auto_saved_snapshot = if current_scene.fetch("elements").any?
          WhiteboardSnapshot.create_from_scene!(
            chat_session: chat_session,
            scene: current_scene,
            kind: "auto_before_load"
          )
        end

        Canvas.mutate(chat_session, tool_name, { "mode" => "replace" }) do |elements, scene|
          snapshot_elements = Canvas.deep_dup_elements(snapshot_scene.fetch("elements"))
          Canvas.ensure_within_element_limit!(snapshot_elements)

          elements.replace(snapshot_elements)
          scene["appState"] = Canvas.deep_dup_scene(snapshot_scene.fetch("appState"))
          scene["files"] = Canvas.deep_dup_scene(snapshot_scene.fetch("files"))

          {
            loaded: true,
            elements_added: snapshot_elements.size,
            auto_saved_snapshot_id: auto_saved_snapshot&.id
          }
        end
      end

      def merge_canvas(chat_session, snapshot_scene)
        Canvas.mutate(chat_session, tool_name, { "mode" => "merge" }) do |elements, scene|
          snapshot_elements = remap_snapshot_elements(snapshot_scene.fetch("elements"))
          if elements.size + snapshot_elements.size > Whiteboard::MAX_ELEMENTS
            raise Canvas::ElementLimitExceeded, Whiteboard.element_limit_message
          end

          elements.concat(snapshot_elements)
          scene["files"].merge!(Canvas.deep_dup_scene(snapshot_scene.fetch("files")))

          {
            loaded: true,
            elements_added: snapshot_elements.size,
            auto_saved_snapshot_id: nil
          }
        end
      end

      def remap_snapshot_elements(elements)
        copied_elements = Canvas.deep_dup_elements(elements)
        id_map = copied_elements.each_with_object({}) do |element, memo|
          old_id = element["id"]
          next if old_id.blank?

          memo[old_id] = ExcalidrawId.generate
          element["id"] = memo.fetch(old_id)
        end

        copied_elements.each do |element|
          remap_element_references!(element, id_map)
        end

        copied_elements
      end

      def remap_element_references!(element, id_map)
        element["containerId"] = id_map.fetch(element["containerId"], element["containerId"]) if element["containerId"]
        element["frameId"] = id_map.fetch(element["frameId"], element["frameId"]) if element["frameId"]
        element["groupIds"] = Array(element["groupIds"]).map { |id| id_map.fetch(id, id) } if element.key?("groupIds")

        Array(element["boundElements"]).each do |bound_element|
          next unless bound_element.is_a?(Hash) && bound_element["id"]

          bound_element["id"] = id_map.fetch(bound_element["id"], bound_element["id"])
        end

        %w[startBinding endBinding].each do |binding_key|
          binding = element[binding_key]
          next unless binding.is_a?(Hash) && binding["elementId"]

          binding["elementId"] = id_map.fetch(binding["elementId"], binding["elementId"])
        end
      end
    end
  end
end
