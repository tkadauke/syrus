require "mcp"

module SyrusChatMcp
  class DeleteProposalTool < MCP::Tool
    tool_name "delete_proposal"

    description <<~DESC
      Discard a proposal by slug. Downstream dependents are discarded too;
      the response lists that cascade so the agent can tell the operator.
    DESC

    input_schema(
      properties: {
        slug: { type: "string", description: "Proposal slug to discard." }
      },
      required: %w[slug]
    )

    class << self
      def call(slug:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        slug = slug.to_s.strip
        return SyrusChatMcp.invalid("slug is required") if slug.empty?

        proposal = chat_session.proposals.find_by(slug: slug)
        return SyrusChatMcp.invalid("unknown proposal slug: #{slug}") unless proposal

        cascade = ChatProposal.transitive_downstream_closure([ proposal ]).to_a
        cascade = ChatProposal.topological_sort(ChatProposal.where(id: cascade.map(&:id)))
        now = Time.current

        proposal.transaction do
          cascade.each do |downstream|
            downstream.update!(state: "discarded", discarded_at: downstream.discarded_at || now)
          end
        end

        SyrusChatMcp.success(
          slug: proposal.slug,
          state: proposal.reload.state,
          cascade: cascade.reject { |downstream| downstream.id == proposal.id }.map { |downstream| SyrusChatMcp.proposal_payload(downstream.reload) }
        )
      rescue ArgumentError => e
        SyrusChatMcp.invalid(e.message)
      end
    end
  end
end
