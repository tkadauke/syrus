require "mcp"

module Mcp::Tools
  class DeleteProposalTool < MCP::Tool
    tool_name "delete_proposal"

    description <<~DESC
      Withdraw a proposal by slug. Downstream dependents are withdrawn too;
      the response lists that cascade so the agent can tell the operator.
      After withdrawal, any replacement proposal must use a new slug —
      reusing a withdrawn slug is an error.
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
        return Mcp::Tools.invalid("slug is required") if slug.empty?

        proposal = chat_session.proposals.find_by(slug: slug)
        return Mcp::Tools.invalid("unknown proposal slug: #{slug}") unless proposal

        cascade = ChatProposal.transitive_downstream_closure([ proposal ]).to_a

        epic_ids = cascade.select(&:epic_bundle?).map(&:id)
        if epic_ids.any?
          children = ChatProposal.where(parent_proposal_id: epic_ids, state: "proposed").to_a
          cascade = (cascade + children).uniq(&:id)
        end

        cascade = ChatProposal.topological_sort(ChatProposal.where(id: cascade.map(&:id)))
        now = Time.current

        proposal.transaction do
          cascade.each do |downstream|
            downstream.update!(state: "withdrawn", discarded_at: downstream.discarded_at || now, withdrawn_at: downstream.withdrawn_at || now)
          end
        end

        cascade.each { |p| Mcp::Tools.broadcast_proposal_created(chat_session, p.reload) }

        Mcp::Tools.success(
          slug: proposal.slug,
          state: proposal.reload.state,
          cascade: cascade.reject { |downstream| downstream.id == proposal.id }.map { |downstream| Mcp::Tools.proposal_payload(downstream.reload) }
        )
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
