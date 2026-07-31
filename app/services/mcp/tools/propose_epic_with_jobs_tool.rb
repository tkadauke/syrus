require "mcp"

module Mcp::Tools
  class ProposeEpicWithJobsTool < MCP::Tool
    tool_name "propose_epic_with_jobs"

    description <<~DESC
      Propose one Epic and its child Syrus Jobs as a single confirmation card.
      If epic.epic_id is provided, the card proposes child Jobs under that
      existing Epic instead of creating a new Epic.
      Job depends_on entries reference sibling job slugs in the same call or
      Job proposal slugs from other proposal cards in this chat session.
      Confirming the card creates the Epic, child Jobs, and sibling Job
      dependencies in one Syrus transaction.
      Proposals cannot be updated after creation. To revise a proposal,
      call delete_proposal with its slug, then call this tool again with a
      new slug. Reusing a withdrawn slug is an error.
      Any `id` in the response is a proposal record ID -- NOT an Epic or Job
      ID. Never write `EPIC-{id}` or `JOB-{id}` using these numbers. The actual
      Epic and Job IDs are assigned only when the operator confirms, and will
      appear as `EPIC-<id>` and `JOB-<id>` in the next turn's system prompt
      under "Recent proposal activity".
      To sequence multiple epics, set epic.depends_on_proposal_slugs on each
      dependent epic card — the system resolves slugs to Epic IDs at
      confirmation time, making post-confirmation add_epic_dependency calls
      unnecessary.
      To sequence this epic after another, set epic.depends_on — this blocks
      ALL child jobs from starting until the referenced epics complete. To block
      only a specific child job while siblings proceed in parallel, use
      jobs[].depends_on_epic_ids instead. When an operator says "set the
      dependency" or "remember to wire the dependency," prefer epic.depends_on
      unless you have a specific reason why some sibling jobs should start sooner.
    DESC

    input_schema(
      properties: {
        epic: {
          type: "object",
          properties: {
            slug: { type: "string", description: "Stable epic proposal slug unique within this chat session." },
            epic_id: { type: "integer", description: "Optional existing Epic id to receive the proposed child Jobs." },
            title: { type: "string", description: "Epic title." },
            description: { type: "string", description: "Epic description." },
            target_repo: { type: "string", description: "Repository slug owner/name. Defaults to the chat repository." },
            depends_on_job_ids: { type: "array", items: { type: "integer" }, description: "Existing Job IDs this Epic depends on." },
            depends_on_proposal_slugs: { type: "array", items: { type: "string" }, description: "Epic proposal slugs in this chat session that this Epic depends on. Declaring this here wires the epic-to-epic dependency automatically at confirmation time — preferred over calling add_epic_dependency afterward." },
            depends_on: { type: "array", items: { type: "string" }, description: "Proposal slugs or string-encoded Epic ids (e.g. `epic:42`) this Epic depends on. Blocks ALL child jobs from starting until these epics complete. Use this when the whole epic must wait for upstream work; use `jobs[].depends_on_epic_ids` only when individual jobs need to wait while siblings can proceed independently." },
            nonlinear_dependency_override: { type: "boolean", description: "Allow the child Jobs to form a nonlinear graph. Set this only when the operator explicitly requested nonlinear execution; otherwise child Jobs must form one chain." }
          },
          required: %w[slug]
        },
        jobs: {
          type: "array",
          items: {
            type: "object",
            properties: {
              slug: { type: "string", description: "Stable sibling job slug unique within this chat session." },
              target_repo: { type: "string", description: "Repository slug owner/name." },
              title: { type: "string", description: "Child Job title." },
              description: { type: "string", description: "Child Job prompt/body." },
              depends_on_epic_ids: { type: "array", items: { type: "integer" }, description: "Existing Epic IDs this child Job (not the whole epic) depends on. Use when only this specific job must wait for an upstream epic while sibling jobs in the same epic can start sooner. For whole-epic sequencing, prefer `epic.depends_on`." },
              depends_on: { type: "array", items: { type: "string" }, description: "Sibling job slugs or job proposal slugs from other cards in this chat session. Default to linear chains — if jobs share a test path (e.g. backend → frontend → agent handoff that consumes both), chain them even when code changes don't overlap directly. Only omit a dependency when the jobs are genuinely independently deployable and testable end-to-end. The operator can instruct otherwise." },
              media: {
                type: "array",
                items: { type: "string" },
                description: "Media references to attach to this child Job. Call save_canvas first to get a snapshot ID (\"snapshot:42\"), or pass chat image IDs as \"chat_image:123\". Omit if no media is relevant."
              }
            },
            required: %w[slug title description]
          },
          description: "Child Jobs to create if the Epic proposal is confirmed."
        }
      },
      required: %w[epic jobs]
    )

    class << self
      def call(epic:, jobs:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        user = chat_session.user

        epic_attrs = normalize_hash(epic)
        job_attrs = Array(jobs).map { |job| normalize_hash(job) }
        return Mcp::Tools.invalid("jobs must include at least one child Job") if job_attrs.empty?

        normalized_epic = normalize_epic(epic_attrs)
        target_epic = target_epic_for(user, normalized_epic[:epic_id])
        return Mcp::Tools.invalid("unknown epic_id: #{normalized_epic[:epic_id]}") if normalized_epic[:epic_id] && !target_epic
        if target_epic&.state&.in?(%w[done archived])
          return Mcp::Tools.invalid("Epic #{normalized_epic[:epic_id]} is #{target_epic.state} — cannot propose a Job into a closed Epic. Re-open the Epic or choose a different one.")
        end

        normalized_epic[:title] = target_epic.title if target_epic && normalized_epic[:title].blank?
        normalized_epic[:description] = target_epic.description.to_s if target_epic && normalized_epic[:description].blank?

        epic_repository = target_epic&.repository || repository_for(user, chat_session, normalized_epic[:target_repo])
        return Mcp::Tools.invalid("unknown epic target_repo: #{normalized_epic[:target_repo]}") unless epic_repository
        if target_epic && normalized_epic[:target_repo].present? && normalized_epic[:target_repo] != epic_repository.slug
          return Mcp::Tools.invalid("epic target_repo must match existing Epic repository")
        end

        normalized_jobs = job_attrs.map { |job| normalize_job(job, default_repo: epic_repository.slug) }
        validation_error = validate_payload(chat_session, user, normalized_epic, normalized_jobs)
        return Mcp::Tools.invalid(validation_error) if validation_error
        dependency_error = validate_epic_dependencies(chat_session, user, normalized_epic[:depends_on])
        return Mcp::Tools.invalid(dependency_error) if dependency_error

        job_repositories = {}
        normalized_jobs.each do |job|
          repository = repository_for(user, chat_session, job[:target_repo])
          return Mcp::Tools.invalid("unknown job target_repo for #{job[:slug]}: #{job[:target_repo]}") unless repository
          return Mcp::Tools.invalid("proposal item #{job[:slug]} target_repo must match the Epic target_repo") unless repository.id == epic_repository.id

          job_repositories[job[:slug]] = repository
        end

        proposal = nil
        ApplicationRecord.transaction do
          proposal = upsert_epic_proposal(chat_session, epic_repository, normalized_epic, target_epic)
          replace_epic_dependency_edges(proposal, chat_session, normalized_epic[:depends_on])
          child_by_slug = upsert_child_proposals(chat_session, proposal, job_repositories, normalized_jobs)
          replace_dependency_edges(chat_session, child_by_slug, normalized_jobs)
          chat_session.messages.create!(
            role: "assistant",
            proposal: proposal,
            content: { "text" => "Epic proposal proposed." }
          )
        end

        Mcp::Tools.broadcast_proposal_created(chat_session, proposal)
        Mcp::Tools.success(payload_for(proposal.reload))
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def normalize_hash(value)
        value.to_h.transform_keys(&:to_s)
      end

      def normalize_epic(epic)
        {
          slug: epic["slug"].to_s.strip,
          epic_id: Integer(epic["epic_id"], exception: false),
          title: epic["title"].to_s.strip,
          description: epic["description"].to_s.strip,
          target_repo: epic["target_repo"].to_s.strip,
          depends_on_job_ids: normalize_integer_list(epic["depends_on_job_ids"]),
          depends_on: normalize_string_list(epic["depends_on"]) | normalize_string_list(epic["depends_on_proposal_slugs"]),
          nonlinear_dependency_override: ActiveModel::Type::Boolean.new.cast(epic["nonlinear_dependency_override"]) == true
        }
      end

      def normalize_job(job, default_repo:)
        {
          slug: job["slug"].to_s.strip,
          title: job["title"].to_s.strip,
          description: job["description"].to_s.strip,
          target_repo: job["target_repo"].to_s.strip.presence || default_repo,
          depends_on_epic_ids: normalize_integer_list(job["depends_on_epic_ids"]),
          depends_on: normalize_string_list(job["depends_on"]),
          media_ids: Array(job["media"])
        }
      end

      def normalize_string_list(value)
        Array(value).map { |item| item.to_s.strip }.reject(&:empty?).uniq
      end

      def normalize_integer_list(value)
        Array(value).filter_map { |item| Integer(item, exception: false) }.uniq
      end

      def validate_payload(chat_session, user, epic, jobs)
        return "epic slug is required" if epic[:slug].empty?
        return "epic title is required" if epic[:title].empty?
        return "epic description is required" if epic[:description].empty?
        return "epic cannot depend on itself" if epic[:depends_on].include?(epic[:slug])

        slugs = jobs.map { |job| job[:slug] }
        return "child job slugs must be unique" if slugs.uniq.length != slugs.length
        return "epic slug must not duplicate a child job slug" if slugs.include?(epic[:slug])

        all_incoming_slugs = [ epic[:slug] ] + slugs
        withdrawn_collision = chat_session.proposals.withdrawn.where(slug: all_incoming_slugs).pluck(:slug).first
        if withdrawn_collision
          return "slug '#{withdrawn_collision}' was already used and withdrawn in this session; use a different slug for the revised proposal"
        end

        jobs.each do |job|
          return "job slug is required" if job[:slug].empty?
          return "proposal item #{job[:slug]} title is required" if job[:title].empty?
          return "proposal item #{job[:slug]} description is required" if job[:description].empty?
          return "proposal item #{job[:slug]} target_repo is required" if job[:target_repo].empty?
          return "proposal item #{job[:slug]} cannot depend on itself" if job[:depends_on].include?(job[:slug])
        end

        dependency_slugs = jobs.flat_map { |job| job[:depends_on] }.uniq
        cross_card_slugs = dependency_slugs - slugs
        known_cross_card_proposals = chat_session.proposals.where(slug: cross_card_slugs).where(kind: %w[syrus_issue job]).to_a
        known_cross_card_slugs = known_cross_card_proposals.map(&:slug)
        unknown = cross_card_slugs - known_cross_card_slugs
        return "unknown depends_on slug(s): #{unknown.join(', ')}" if unknown.any?
        target_error = invalid_dependency_target_message(known_cross_card_proposals.filter_map(&:job))
        return target_error if target_error
        unknown_job_ids = epic[:depends_on_job_ids] - user.jobs.where(id: epic[:depends_on_job_ids]).pluck(:id)
        return "unknown epic depends_on_job_ids: #{unknown_job_ids.join(', ')}" if unknown_job_ids.any?
        target_error = invalid_dependency_target_message(user.jobs.where(id: epic[:depends_on_job_ids]))
        return target_error if target_error
        unknown_epic_ids = jobs.flat_map { |job| job[:depends_on_epic_ids] }.uniq
        unknown_epic_ids -= user.epics.where(id: unknown_epic_ids).pluck(:id)
        return "unknown job depends_on_epic_ids: #{unknown_epic_ids.join(', ')}" if unknown_epic_ids.any?
        target_error = invalid_dependency_target_message(user.epics.where(id: jobs.flat_map { |job| job[:depends_on_epic_ids] }.uniq))
        return target_error if target_error
        return "depends_on would create a cycle" if cyclic?(jobs)

        nil
      end

      def cyclic?(jobs)
        slugs = jobs.map { |job| job[:slug] }
        dependencies_by_slug = jobs.to_h { |job| [ job[:slug], job[:depends_on] & slugs ] }
        visiting = {}
        visited = {}

        visit = lambda do |slug|
          return true if visiting[slug]
          return false if visited[slug]

          visiting[slug] = true
          if dependencies_by_slug.fetch(slug).any? { |dependency| visit.call(dependency) }
            return true
          end

          visiting.delete(slug)
          visited[slug] = true
          false
        end

        dependencies_by_slug.keys.any? { |slug| visit.call(slug) }
      end

      def validate_epic_dependencies(chat_session, user, depends_on)
        depends_on.each do |token|
          if token.match?(/\Aepic:\d+\z/)
            epic_id = token.split(":", 2).last
            epic = user.epics.find_by(id: epic_id)
            return "unknown depends_on Epic id: #{epic_id}" unless epic

            target_error = invalid_dependency_target_message([ epic ])
            return target_error if target_error
          else
            proposal = chat_session.proposals.find_by(slug: token)
            return "unknown depends_on slug: #{token}" unless proposal
            return "depends_on slug must reference an Epic proposal: #{token}" unless proposal.epic?

            target_error = invalid_dependency_target_message([ proposal.epic ].compact)
            return target_error if target_error
          end
        end

        nil
      end

      def invalid_dependency_target_message(targets)
        Array(targets).each do |target|
          ProposalDependencyValidator.validate!(target)
        rescue ArgumentError => e
          return e.message
        end

        nil
      end

      def repository_for(user, chat_session, slug)
        if slug.blank?
          repository = chat_session.repository
          return repository unless repository&.archived?

          return nil
        end

        owner, name = slug.split("/", 2)
        return nil if owner.blank? || name.blank?

        # Cross-repo Epic proposals are allowed only within the current user's
        # active repository scope.
        user.repositories.active.find_by(owner: owner, name: name)
      end

      def target_epic_for(user, epic_id)
        return unless epic_id

        user.epics.includes(:repository).find_by(id: epic_id)
      end

      def upsert_epic_proposal(chat_session, repository, epic, target_epic)
        proposal = chat_session.proposals.find_or_initialize_by(slug: epic[:slug])
        proposal.assign_attributes(
          repository: repository,
          target_epic: target_epic,
          parent_proposal: nil,
          title: epic[:title],
          body: epic[:description],
          kind: "epic",
          labels: nil,
          depends_on_job_ids: epic[:depends_on_job_ids],
          epic_depends_on_tokens: JSON.generate(epic[:depends_on]),
          nonlinear_dependency_override: epic[:nonlinear_dependency_override],
          state: "proposed",
          edited_at: proposal.persisted? ? Time.current : nil
        )
        proposal.save!
        proposal
      end

      def upsert_child_proposals(chat_session, parent, repositories_by_slug, jobs)
        child_by_slug = {}
        jobs.each_with_index do |job, index|
          child = chat_session.proposals.find_or_initialize_by(slug: job[:slug])
          if child.persisted? && child.parent_proposal_id.present? && child.parent_proposal_id != parent.id
            raise ActiveRecord::RecordInvalid.new(child.tap { |record| record.errors.add(:slug, "already belongs to another Epic proposal") })
          end

          child.assign_attributes(
            repository: repositories_by_slug.fetch(job[:slug]),
            parent_proposal: parent,
            child_position: index,
            title: job[:title],
            body: job[:description],
            kind: "syrus_issue",
            labels: nil,
            depends_on_epic_ids: job[:depends_on_epic_ids],
            media_ids: job[:media_ids],
            state: "proposed",
            edited_at: child.persisted? ? Time.current : nil
          )
          child.save!
          child_by_slug[job[:slug]] = child
        end
        child_by_slug
      end

      def replace_dependency_edges(chat_session, child_by_slug, jobs)
        child_by_slug.each_value { |proposal| proposal.dependency_edges.destroy_all }
        jobs.each do |job|
          proposal = child_by_slug.fetch(job[:slug])
          job[:depends_on].each do |dependency_slug|
            ChatProposalDependency.create!(
              proposal: proposal,
              depends_on: child_by_slug[dependency_slug] || chat_session.proposals.find_by!(slug: dependency_slug)
            )
          end
        end
      end

      def replace_epic_dependency_edges(proposal, chat_session, depends_on)
        proposal.dependency_edges.destroy_all
        depends_on.reject { |token| token.match?(/\Aepic:\d+\z/) }.each do |slug|
          ChatProposalDependency.create!(
            proposal: proposal,
            depends_on: chat_session.proposals.find_by!(slug: slug)
          )
        end
      end

      def payload_for(proposal)
        {
          id: proposal.id,
          slug: proposal.slug,
          state: proposal.state,
          kind: proposal.kind,
          target_epic: Mcp::Tools.target_epic_payload(proposal),
          depends_on: proposal.epic_dependency_tokens,
          depends_on_proposal_slugs: proposal.epic_dependency_tokens.reject { |token| token.match?(/\Aepic:\d+\z/) },
          nonlinear_dependency_override: proposal.nonlinear_dependency_override?,
          child_jobs: proposal.child_proposals.map do |child|
            {
              id: child.id,
              slug: child.slug,
              state: child.state,
              target_repo: child.repository&.slug,
              depends_on_epic_ids: child.depends_on_epic_ids,
              depends_on: child.dependencies.order(:slug).pluck(:slug)
            }
          end
        }
      end
    end
  end
end
