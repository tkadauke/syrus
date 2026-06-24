require "mcp"

module SyrusChatMcp
  class CreateTagTool < MCP::Tool
    tool_name "create_tag"

    description "Create a tag for the current chat user."

    input_schema(
      properties: {
        name: { type: "string", description: "Tag name." },
        color: { type: "string", description: "Palette key or #rrggbb color. Defaults to gray." }
      },
      required: %w[name]
    )

    class << self
      def call(name:, server_context:, color: nil)
        chat_session = server_context.fetch(:chat_session)
        tag = chat_session.user.tags.create(name: name, color: color.presence || "gray")
        return SyrusChatMcp.invalid(tag.errors.full_messages.to_sentence) unless tag.persisted?

        SyrusChatMcp.success(tag_payload(tag))
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
