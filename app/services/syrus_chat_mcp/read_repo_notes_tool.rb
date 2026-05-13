require "mcp"

module SyrusChatMcp
  class ReadRepoNotesTool < MCP::Tool
    tool_name "read_repo_notes"

    description "Read all active pinned notes for this chat's repository."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        notes = chat_session.repository.repository_notes.active.order(:created_at, :id)

        SyrusChatMcp.success(notes: notes.map { |note| SyrusChatMcp.repository_note_payload(note) })
      end
    end
  end
end
