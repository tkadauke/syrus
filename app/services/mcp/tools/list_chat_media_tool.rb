require "mcp"

module Mcp::Tools
  class ListChatMediaTool < MCP::Tool
    tool_name "list_chat_media"

    description "List media available in this chat session that can be attached to a Job proposal or to chat feedback on an existing Job. Pass the returned IDs to propose_job's or submit_chat_feedback's media array."

    input_schema(properties: {})

    class << self
      # The kinds come from the registered media sources; the grouped keys
      # below are the shape the chat UI's media gallery already reads.
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        ChatMediaLibrary.materialize_inline_images!(chat_session)

        entries = []
        context = {}

        ChatMediaSources.all.each do |source|
          entries.concat(Array(source.list_chat_media(chat_session: chat_session)))
          context.merge!(source.chat_media_context(chat_session: chat_session).to_h)
        end

        Mcp::Tools.success(
          snapshots: entries.select { |entry| entry[:kind].to_s == "snapshot" },
          chat_images: entries.select { |entry| entry[:kind].to_s == "chat_image" },
          **context
        )
      end
    end
  end
end
