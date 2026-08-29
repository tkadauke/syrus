require "mcp"

module Mcp::Tools
  class ProposeJobTool < MCP::Tool
    extend ProposalToolSupport

    tool_name "propose_job"

    description <<~DESC
      Create a Job proposal card. If epic_id is provided, confirming the
      card creates the Job under that Epic. Without epic_id, confirming
      creates an epicless direct Job.
      Syrus Epics execute as one stacked branch, not parallel branches, so a
      Job proposed into an Epic that already has Jobs is REQUIRED to set
      depends_on_job_ids to that Epic's current tail Job (read the Epic's
      Jobs first if you don't already know its current tail) — otherwise it
      would materialize as a disconnected parallel branch (no
      depends_on_job_ids naming an existing Job), a fork (chaining onto a
      Job that already has a downstream child in the Epic), or a merge
      (chaining onto more than one existing Job at once), and the tool
      rejects it before creating the proposal card. For proposing an Epic
      together with a batch of new child Jobs in one call, prefer
      propose_epic_with_jobs instead, which also validates the whole batch
      as a single chain.
      Proposals cannot be updated after creation. To revise a proposal,
      call delete_proposal with its slug, then call this tool again with a
      new title or different input so a new slug is generated.
      The `id` in the response is the proposal record ID -- NOT the Job ID.
      Never write `JOB-{id}` using this number. The actual Job ID is assigned
      only when the operator confirms, and will appear as `JOB-<id>` in the
      next turn's system prompt under "Recent proposal activity".
      To attach the current whiteboard, call save_canvas first and pass the
      returned snapshot_id as "snapshot:ID" in the media array.
      To hand the implementation agent a preview panel mockup's source files,
      pass the panel's current version id as "preview_panel_version:ID" in
      the media array (show_preview's response includes version_id). Frame
      the mockup in the Job description as reference material describing the
      intended look and behavior for the implementing agent to adapt to the
      target repo's own conventions -- not boilerplate to copy verbatim.
      Format description as normal Markdown with real newline characters
      between paragraphs, lists, and code fences. Do not write literal
      backslash-n sequences (`\\n`) into the description; those are plain
      text and will render as one long unreadable line.
    DESC

    input_schema(
      properties: {
        epic_id: { type: "integer", description: "Optional target Epic id." },
        repo: { type: "string", description: "Repository id, name, or owner/name slug." },
        title: { type: "string", description: "Job title." },
        description: { type: "string", description: "Markdown Job description. Use real newline characters for paragraphs, lists, and code fences; do not include literal backslash-n sequences (`\\n`)." },
        depends_on_epic_ids: { type: "array", items: { type: "integer" }, description: "Optional existing Epic IDs this Job depends on." },
        depends_on_job_ids: { type: "array", items: { type: "integer" }, description: "Existing Job IDs this Job depends on. Required to include one of the target Epic's existing Jobs when epic_id targets a non-empty Epic — this is how a new Job chains onto that Epic's stack instead of becoming a disconnected parallel branch." },
        depends_on: { type: "array", items: { type: "string" }, description: "Optional Job proposal slugs from this chat session. Prefer declaring a dependency when this job builds on or needs to be tested against another proposal in the same session; omit only when the work is genuinely independent. The operator can instruct otherwise." },
        media: {
          type: "array",
          items: { type: "string" },
          description: "Media references to attach to the Job. Call save_canvas first to get a snapshot ID (\"snapshot:42\"), pass chat image IDs as \"chat_image:123\", or pass a preview panel's current version id as \"preview_panel_version:42\" to hand the implementing agent that mockup's source files. Omit if no media is relevant."
        }
      },
      required: %w[repo title description]
    )

    class << self
      def call(repo:, title:, description:, server_context:, epic_id: nil, depends_on: [], depends_on_epic_ids: [], depends_on_job_ids: [], media: [])
        chat_session = server_context.fetch(:chat_session)
        repository = repository_for(chat_session, repo)
        title = title.to_s.strip
        description = description.to_s.strip
        depends_on_epic_ids = normalize_integer_list(depends_on_epic_ids)
        depends_on_job_ids = normalize_integer_list(depends_on_job_ids)

        return Mcp::Tools.invalid("repo is required") if repo.to_s.strip.empty?
        return Mcp::Tools.invalid("repository not found") unless repository
        return Mcp::Tools.invalid("title is required") if title.empty?
        return Mcp::Tools.invalid("description is required") if description.empty?

        target_epic = target_epic_for(chat_session, repository, epic_id)
        return Mcp::Tools.invalid("epic_id was not found in #{repository.slug}") if epic_id.present? && !target_epic
        if target_epic && target_epic.state.in?(%w[done archived])
          return Mcp::Tools.invalid("Epic #{epic_id} is #{target_epic.state} — cannot propose a Job into a closed Epic. Re-open the Epic or choose a different one.")
        end

        dependencies, unknown_slugs = dependency_proposals(chat_session, depends_on)
        return Mcp::Tools.invalid("unknown depends_on slug(s): #{unknown_slugs.join(', ')}") if unknown_slugs.any?
        non_job_dependency = dependencies.find { |dependency| !dependency.syrus_issue? && !dependency.job? }
        return Mcp::Tools.invalid("depends_on slug must reference a Job proposal: #{non_job_dependency.slug}") if non_job_dependency
        dependency_error = proposal_dependency_target_error(dependencies)
        return Mcp::Tools.invalid(dependency_error) if dependency_error
        unknown_epic_ids = unknown_epic_dependency_ids(chat_session, depends_on_epic_ids)
        return Mcp::Tools.invalid("unknown depends_on_epic_ids: #{unknown_epic_ids.join(', ')}") if unknown_epic_ids.any?
        dependency_error = dependency_target_error(chat_session.user.epics, depends_on_epic_ids)
        return Mcp::Tools.invalid(dependency_error) if dependency_error
        unknown_job_ids = unknown_job_dependency_ids(chat_session, depends_on_job_ids)
        return Mcp::Tools.invalid("unknown depends_on_job_ids: #{unknown_job_ids.join(', ')}") if unknown_job_ids.any?
        dependency_error = dependency_target_error(chat_session.user.jobs, depends_on_job_ids)
        return Mcp::Tools.invalid(dependency_error) if dependency_error
        if target_epic && target_epic.jobs.exists?
          if (depends_on_job_ids & target_epic.jobs.pluck(:id)).empty?
            return Mcp::Tools.invalid(
              "Epic #{epic_id} already has Jobs — Syrus Epics execute as one stacked branch, not parallel " \
              "branches, so this Job must chain onto the Epic via depends_on_job_ids naming one of its " \
              "existing Jobs (read the Epic's Jobs first if you don't already know its current tail), or it " \
              "would become a disconnected parallel branch."
            )
          end

          linear_chain_error = linear_chain_violation_message(target_epic, depends_on_job_ids, title)
          return Mcp::Tools.invalid(linear_chain_error) if linear_chain_error
        end

        proposal = nil
        ChatProposal.transaction do
          proposal = chat_session.proposals.create!(
            repository: repository,
            target_epic: target_epic,
            slug: unique_slug(chat_session, title, prefix: "job"),
            title: title,
            body: description,
            kind: "job",
            depends_on_epic_ids: depends_on_epic_ids,
            depends_on_job_ids: depends_on_job_ids,
            media_ids: Array(media),
            **ChatGoalProvenance.attributes_for(chat_session)
          )
          dependencies.each do |dependency|
            ChatProposalDependency.create!(proposal: proposal, depends_on: dependency)
          end
          create_proposal_message!(chat_session, proposal, text: "Job proposal proposed.")
        end

        Mcp::Tools.broadcast_proposal_created(chat_session, proposal)
        Mcp::Tools.success(Mcp::Tools.proposal_payload(proposal))
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      # Folds the not-yet-persisted proposal in as a synthetic node alongside
      # the target Epic's existing Jobs (and their same-epic JobDependency
      # edges), then runs it through the same single-chain graph check
      # ChatEpicProposalMaterializer uses at confirmation time. This catches
      # fork (chaining onto a Job that already has a downstream child) and
      # merge (chaining onto more than one existing Job) before the proposal
      # card is created, not just the "no chain at all" case checked above.
      def linear_chain_violation_message(target_epic, depends_on_job_ids, title)
        existing_jobs = target_epic.jobs.to_a
        new_key = "new_job"
        labels_by_key = { new_key => title }
        existing_jobs.each { |job| labels_by_key[EpicDependencyPolicy::Linear.job_key(job.id)] = job.slug }

        edges = depends_on_job_ids
                  .select { |job_id| existing_jobs.any? { |existing| existing.id == job_id } }
                  .map { |job_id| [ new_key, EpicDependencyPolicy::Linear.job_key(job_id) ] }
        JobDependency.where(job_id: existing_jobs.map(&:id), depends_on_job_id: existing_jobs.map(&:id))
                     .pluck(:job_id, :depends_on_job_id)
                     .each { |dependent_id, dependency_id| edges << [ EpicDependencyPolicy::Linear.job_key(dependent_id), EpicDependencyPolicy::Linear.job_key(dependency_id) ] }

        EpicDependencyPolicy::Linear.validate_chain!(labels_by_key: labels_by_key, edges: edges)
        nil
      rescue ArgumentError => e
        e.message
      end
    end
  end
end
