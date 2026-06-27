require "mcp"

module SyrusChatMcp
  class ProposeEpicTool < MCP::Tool
    extend ProposalToolSupport

    tool_name "propose_epic"

    description <<~DESC
      Create an Epic-only proposal card. Confirming the card creates the
      Epic by itself, with no child Jobs.
      Proposals cannot be updated after creation. To revise a proposal,
      call delete_proposal with its slug, then call this tool again.
      The `id` in the response is the proposal record ID -- NOT the Epic ID.
      Never write `EPIC-{id}` using this number. The actual Epic ID is assigned
      only when the operator confirms, and will appear as `EPIC-<id>` in the
      next turn's system prompt under "Recent proposal activity".
    DESC

    input_schema(
      properties: {
        title: { type: "string", description: "Epic title." },
        description: { type: "string", description: "Markdown Epic description." },
        attached_repos: { type: "array", items: { type: "string" }, description: "Optional repository slugs or ids. The first repo is used as the Epic repository." },
        depends_on_job_ids: { type: "array", items: { type: "integer" }, description: "Optional existing Job IDs this Epic depends on." },
        depends_on: { type: "array", items: { type: "string" }, description: "Optional proposal slugs that must be confirmed first." }
      },
      required: %w[title description]
    )

    class << self
      def call(title:, description:, server_context:, attached_repos: [], depends_on: [], depends_on_job_ids: [])
        chat_session = server_context.fetch(:chat_session)
        title = title.to_s.strip
        description = description.to_s.strip
        repo_tokens = normalize_string_list(attached_repos)
        repository = repository_for(chat_session, repo_tokens.first)
        depends_on_job_ids = normalize_integer_list(depends_on_job_ids)

        return SyrusChatMcp.invalid("title is required") if title.empty?
        return SyrusChatMcp.invalid("description is required") if description.empty?
        return SyrusChatMcp.invalid("repository not found") unless repository

        dependencies, unknown_slugs = dependency_proposals(chat_session, depends_on)
        return SyrusChatMcp.invalid("unknown depends_on slug(s): #{unknown_slugs.join(', ')}") if unknown_slugs.any?
        unknown_job_ids = unknown_job_dependency_ids(chat_session, depends_on_job_ids)
        return SyrusChatMcp.invalid("unknown depends_on_job_ids: #{unknown_job_ids.join(', ')}") if unknown_job_ids.any?

        proposal = nil
        ChatProposal.transaction do
          proposal = chat_session.proposals.create!(
            repository: repository,
            slug: unique_slug(chat_session, title, prefix: "epic"),
            title: title,
            body: description,
            kind: "epic",
            depends_on_job_ids: depends_on_job_ids
          )
          dependencies.each do |dependency|
            ChatProposalDependency.create!(proposal: proposal, depends_on: dependency)
          end
          create_proposal_message!(chat_session, proposal, text: "Epic proposal proposed.")
        end

        SyrusChatMcp.success(SyrusChatMcp.proposal_payload(proposal))
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
