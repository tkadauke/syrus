require "mcp"

module SyrusChatMcp
  class ListProposalsTool < MCP::Tool
    tool_name "list_proposals"

    description "List every proposal in this chat session, including filed and discarded proposals."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        proposals = ChatProposal.topological_sort(chat_session.proposals.includes(:dependencies).order(:created_at, :id))

        SyrusChatMcp.success(
          proposals: proposals.map { |proposal| SyrusChatMcp.proposal_payload(proposal) }
        )
      rescue ArgumentError => e
        SyrusChatMcp.invalid(e.message)
      end
    end
  end
end
