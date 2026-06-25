require "mcp"

module SyrusChatMcp
  class ProposeJobTool < MCP::Tool
    extend ProposalToolSupport

    tool_name "propose_job"

    description <<~DESC
      Create a Job proposal card. If epic_id is provided, confirming the
      card creates the Job under that Epic. Without epic_id, confirming
      creates an epicless direct Job.
    DESC

    input_schema(
      properties: {
        epic_id: { type: "integer", description: "Optional target Epic id." },
        repo: { type: "string", description: "Repository id, name, or owner/name slug." },
        title: { type: "string", description: "Job title." },
        description: { type: "string", description: "Markdown Job description." },
        depends_on_epic_ids: { type: "array", items: { type: "integer" }, description: "Optional existing Epic IDs this Job depends on." },
        depends_on: { type: "array", items: { type: "string" }, description: "Optional proposal slugs that must be confirmed first. Prefer declaring a dependency when this job builds on or needs to be tested against another proposal in the same session; omit only when the work is genuinely independent. The operator can instruct otherwise." }
      },
      required: %w[repo title description]
    )

    class << self
      def call(repo:, title:, description:, server_context:, epic_id: nil, depends_on: [], depends_on_epic_ids: [])
        chat_session = server_context.fetch(:chat_session)
        repository = repository_for(chat_session, repo)
        title = title.to_s.strip
        description = description.to_s.strip
        depends_on_epic_ids = normalize_integer_list(depends_on_epic_ids)

        return SyrusChatMcp.invalid("repo is required") if repo.to_s.strip.empty?
        return SyrusChatMcp.invalid("repository not found") unless repository
        return SyrusChatMcp.invalid("title is required") if title.empty?
        return SyrusChatMcp.invalid("description is required") if description.empty?

        target_epic = target_epic_for(chat_session, repository, epic_id)
        return SyrusChatMcp.invalid("epic_id was not found in #{repository.slug}") if epic_id.present? && !target_epic

        dependencies, unknown_slugs = dependency_proposals(chat_session, depends_on)
        return SyrusChatMcp.invalid("unknown depends_on slug(s): #{unknown_slugs.join(', ')}") if unknown_slugs.any?
        unknown_epic_ids = unknown_epic_dependency_ids(chat_session, depends_on_epic_ids)
        return SyrusChatMcp.invalid("unknown depends_on_epic_ids: #{unknown_epic_ids.join(', ')}") if unknown_epic_ids.any?

        proposal = nil
        ChatProposal.transaction do
          proposal = chat_session.proposals.create!(
            repository: repository,
            target_epic: target_epic,
            slug: unique_slug(chat_session, title, prefix: "job"),
            title: title,
            body: description,
            kind: "job",
            depends_on_epic_ids: depends_on_epic_ids
          )
          dependencies.each do |dependency|
            ChatProposalDependency.create!(proposal: proposal, depends_on: dependency)
          end
          create_proposal_message!(chat_session, proposal, text: "Job proposal proposed.")
        end

        SyrusChatMcp.success(SyrusChatMcp.proposal_payload(proposal))
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
