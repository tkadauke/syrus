require "mcp"

module Mcp::Tools
  class ListChatMediaTool < MCP::Tool
    tool_name "list_chat_media"

    description "List media available in this chat session that can be attached to a Job proposal. Returns whiteboard snapshots (use save_canvas to create one) and chat image attachments. Pass the returned IDs to propose_job in the media array."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        ChatMediaLibrary.materialize_inline_images!(chat_session)

        snapshots = chat_session.whiteboard_snapshots.limit(10).map { |s| snapshot_payload(s) }

        images = chat_session.attached_repository_documents
                             .newest_first
                             .to_a
                             .select { |doc| doc.content_type.to_s.start_with?("image/") }
                             .map { |doc| image_payload(doc) }

        element_count = chat_session.whiteboard&.elements&.size || 0

        Mcp::Tools.success(
          snapshots: snapshots,
          chat_images: images,
          whiteboard_element_count: element_count
        )
      end

      private

      def snapshot_payload(snapshot)
        {
          id: "snapshot:#{snapshot.id}",
          kind: "snapshot",
          name: snapshot.name,
          element_count: snapshot.element_count,
          created_at: snapshot.created_at&.iso8601
        }
      end

      def image_payload(doc)
        {
          id: "chat_image:#{doc.id}",
          kind: "chat_image",
          filename: doc.filename,
          content_type: doc.content_type
        }
      end
    end
  end
end
