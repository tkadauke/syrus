require "mcp"

module SyrusChatMcp
  class ProposeEpicTool < MCP::Tool
    tool_name "propose_epic"

    description <<~DESC
      Create or update an Epic proposal in this repository chat session.
      Slugs are idempotent within the session. depends_on entries must name
      existing proposal slugs in this same session, and dependency cycles are
      rejected as tool errors.
    DESC

    input_schema(
      properties: {
        slug: { type: "string", description: "Stable proposal slug unique within this chat session." },
        title: { type: "string", description: "Epic title to create if the proposal is accepted." },
        body: { type: "string", description: "Markdown Epic description to create if the proposal is accepted." },
        depends_on: { type: "array", items: { type: "string" }, description: "Proposal slugs that must be confirmed first." }
      },
      required: %w[slug title body]
    )

    class << self
      def call(slug:, title:, body:, server_context:, depends_on: [])
        proposal = ChatProposalProposer.new(
          chat_session: server_context.fetch(:chat_session),
          allowed_kinds: %w[epic]
        ).propose!(
          slug: slug,
          title: title,
          body: body,
          kind: "epic",
          depends_on: depends_on
        )

        SyrusChatMcp.success(
          id: proposal.id,
          slug: proposal.slug,
          state: proposal.state
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      rescue ArgumentError => e
        SyrusChatMcp.invalid(e.message)
      end
    end
  end
end
