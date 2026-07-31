require "mcp"

module Mcp::Tools
  class ProposeEpicTool < MCP::Tool
    extend ProposalToolSupport

    tool_name "propose_epic"

    description <<~DESC
      Create an Epic-only proposal card. Confirming the card creates the
      Epic by itself, with no child Jobs.
      Proposals cannot be updated after creation. To revise a proposal,
      call delete_proposal with its slug, then call this tool again with a
      new title or different input so a new slug is generated.
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
        depends_on_proposal_slugs: { type: "array", items: { type: "string" }, description: "Optional Epic proposal slugs in this chat session that this Epic depends on. Prefer this over calling add_epic_dependency after confirmation — declaring it here wires the epic-to-epic ordering automatically in a single transaction at confirmation time." },
        depends_on: { type: "array", items: { type: "string" }, description: "Optional proposal slugs or string-encoded Epic ids (e.g. epic:42) that must be confirmed first. For cross-epic sequencing, prefer depends_on_proposal_slugs — both fields are merged, but depends_on_proposal_slugs is more explicit." }
      },
      required: %w[title description]
    )

    class << self
      def call(title:, description:, server_context:, attached_repos: [], depends_on: [], depends_on_job_ids: [], depends_on_proposal_slugs: [])
        chat_session = server_context.fetch(:chat_session)
        title = title.to_s.strip
        description = description.to_s.strip
        repo_tokens = normalize_string_list(attached_repos)
        repository = repository_for(chat_session, repo_tokens.first)
        depends_on_job_ids = normalize_integer_list(depends_on_job_ids)
        epic_dependency_slugs = normalize_string_list(depends_on_proposal_slugs) | normalize_string_list(depends_on)

        return Mcp::Tools.invalid("title is required") if title.empty?
        return Mcp::Tools.invalid("description is required") if description.empty?
        return Mcp::Tools.invalid("repository not found") unless repository

        dependencies, unknown_slugs = dependency_proposals(chat_session, epic_dependency_slugs)
        return Mcp::Tools.invalid("unknown depends_on_proposal_slugs: #{unknown_slugs.join(', ')}") if unknown_slugs.any?
        non_epic_slugs = dependencies.reject(&:epic?).map(&:slug)
        return Mcp::Tools.invalid("depends_on_proposal_slugs must reference Epic proposals: #{non_epic_slugs.join(', ')}") if non_epic_slugs.any?
        dependency_error = proposal_dependency_target_error(dependencies)
        return Mcp::Tools.invalid(dependency_error) if dependency_error
        unknown_job_ids = unknown_job_dependency_ids(chat_session, depends_on_job_ids)
        return Mcp::Tools.invalid("unknown depends_on_job_ids: #{unknown_job_ids.join(', ')}") if unknown_job_ids.any?
        dependency_error = dependency_target_error(chat_session.user.jobs, depends_on_job_ids)
        return Mcp::Tools.invalid(dependency_error) if dependency_error

        proposal = nil
        ChatProposal.transaction do
          proposal = chat_session.proposals.create!(
            repository: repository,
            slug: unique_slug(chat_session, title, prefix: "epic"),
            title: title,
            body: description,
            kind: "epic",
            depends_on_job_ids: depends_on_job_ids,
            epic_depends_on_tokens: JSON.generate(epic_dependency_slugs)
          )
          dependencies.each do |dependency|
            ChatProposalDependency.create!(proposal: proposal, depends_on: dependency)
          end
          create_proposal_message!(chat_session, proposal, text: "Epic proposal proposed.")
        end

        Mcp::Tools.broadcast_proposal_created(chat_session, proposal)
        Mcp::Tools.success(Mcp::Tools.proposal_payload(proposal))
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
