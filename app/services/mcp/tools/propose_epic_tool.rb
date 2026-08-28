require "mcp"

module Mcp::Tools
  class ProposeEpicTool < MCP::Tool
    extend ProposalToolSupport

    tool_name "propose_epic"

    description <<~DESC
      DEPRECATED: always rejects. A confirmed Epic with zero child Jobs
      implements nothing, so bare Epic-only proposals are no longer
      allowed. Call propose_epic_with_jobs instead -- it proposes the
      Epic together with at least one child Job in the same card, and
      still accepts epic-level depends_on / depends_on_proposal_slugs
      for sequencing.
    DESC

    input_schema(
      properties: {
        title: { type: "string", description: "Epic title." },
        description: { type: "string", description: "Markdown Epic description." },
        attached_repos: { type: "array", items: { type: "string" }, description: "Optional repository slugs or ids. The first repo is used as the Epic repository." },
        depends_on_job_ids: { type: "array", items: { type: "integer" }, description: "Optional existing Job IDs this Epic depends on." },
        depends_on_proposal_slugs: { type: "array", items: { type: "string" }, description: "Optional Epic proposal slugs in this chat session that this Epic depends on. Prefer this over calling add_epic_dependency after confirmation — declaring it here wires the epic-to-epic ordering automatically in a single transaction at confirmation time." },
        depends_on: { type: "array", items: { type: "string" }, description: "Optional proposal slugs or string-encoded Epic ids (e.g. epic:42) that must be confirmed first. For cross-epic sequencing, prefer depends_on_proposal_slugs — both fields are merged, but depends_on_proposal_slugs is more explicit." }
      },
      required: %w[title description]
    )

    class << self
      def call(title:, description:, server_context:, attached_repos: [], depends_on: [], depends_on_job_ids: [], depends_on_proposal_slugs: [])
        Mcp::Tools.invalid(
          "propose_epic no longer accepts zero-child Epic proposals -- a confirmed Epic with no " \
          "child Jobs implements nothing. Call propose_epic_with_jobs instead, which proposes the " \
          "Epic together with at least one child Job in the same card."
        )
      end
    end
  end
end
