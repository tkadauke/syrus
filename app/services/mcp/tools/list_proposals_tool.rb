require "mcp"

module Mcp::Tools
  class ListProposalsTool < MCP::Tool
    tool_name "list_proposals"

    description "List every proposal in this chat session, including filed and discarded proposals."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        proposals = ChatProposal.topological_sort(chat_session.proposals.includes(:dependencies).order(:created_at, :id))

        Mcp::Tools.success(
          proposals: proposals.map { |proposal| Mcp::Tools.proposal_payload(proposal) }
        )
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
