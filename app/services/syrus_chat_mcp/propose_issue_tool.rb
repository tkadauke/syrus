require "mcp"

module SyrusChatMcp
  class ProposeIssueTool < MCP::Tool
    tool_name "propose_issue"

    description <<~DESC
      Create or update a proposal for work in this repository chat session.
      Slugs are idempotent within the session. depends_on entries must name
      existing proposal slugs in this same session, and dependency cycles are
      rejected as tool errors.
    DESC

    input_schema(
      properties: {
        slug: { type: "string", description: "Stable proposal slug unique within this chat session." },
        title: { type: "string", description: "Issue title to file if the proposal is accepted." },
        body: { type: "string", description: "Markdown issue body to file if the proposal is accepted." },
        kind: { type: "string", enum: %w[syrus_issue github_issue], description: "Proposal filing mode. Defaults to syrus_issue." },
        labels: { type: "array", items: { type: "string" }, description: "Optional GitHub labels to apply when filed." },
        depends_on: { type: "array", items: { type: "string" }, description: "Proposal slugs that must be filed first." }
      },
      required: %w[slug title body]
    )

    class << self
      def call(slug:, title:, body:, server_context:, kind: "syrus_issue", labels: [], depends_on: [])
        chat_session = server_context.fetch(:chat_session)
        slug = slug.to_s.strip
        title = title.to_s.strip
        body = body.to_s.strip
        kind = kind.to_s.presence || "syrus_issue"
        labels = normalize_string_list(labels)
        dependency_slugs = normalize_string_list(depends_on)

        return SyrusChatMcp.invalid("slug is required") if slug.empty?
        return SyrusChatMcp.invalid("title is required") if title.empty?
        return SyrusChatMcp.invalid("body is required") if body.empty?
        return SyrusChatMcp.invalid("kind must be syrus_issue or github_issue") unless ChatProposal.kinds.key?(kind)

        proposal = ChatProposalProposer.new(
          chat_session: chat_session,
          allowed_kinds: %w[syrus_issue github_issue]
        ).propose!(
          slug: slug,
          title: title,
          body: body,
          kind: kind,
          labels: labels,
          depends_on: dependency_slugs
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

      private

      def normalize_string_list(value)
        Array(value).map { |item| item.to_s.strip }.reject(&:empty?).uniq
      end
    end
  end
end
