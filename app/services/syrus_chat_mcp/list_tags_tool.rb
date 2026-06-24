require "mcp"

module SyrusChatMcp
  class ListTagsTool < MCP::Tool
    tool_name "list_tags"

    description "List tags owned by the current chat user."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        SyrusChatMcp.success(tags: chat_session.user.tags.ordered.map { |tag| tag_payload(tag) })
      end

      private

      def tag_payload(tag)
        {
          id: tag.id,
          name: tag.name,
          color: tag.color
        }
      end
    end
  end
end
