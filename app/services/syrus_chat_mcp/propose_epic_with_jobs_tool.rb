require "mcp"

module SyrusChatMcp
  class ProposeEpicWithJobsTool < MCP::Tool
    tool_name "propose_epic_with_jobs"

    description <<~DESC
      Propose one Epic and its child Syrus Jobs as a single confirmation card.
      Job depends_on entries reference sibling job slugs in the same call.
      Confirming the card creates the Epic, child Jobs, and sibling Job
      dependencies in one Syrus transaction.
    DESC

    input_schema(
      properties: {
        epic: {
          type: "object",
          properties: {
            slug: { type: "string", description: "Stable epic proposal slug unique within this chat session." },
            title: { type: "string", description: "Epic title." },
            description: { type: "string", description: "Epic description." },
            target_repo: { type: "string", description: "Repository slug owner/name. Defaults to the chat repository." },
            depends_on_job_ids: { type: "array", items: { type: "integer" }, description: "Existing Job IDs this Epic depends on." }
          },
          required: %w[slug title description]
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
              depends_on_epic_ids: { type: "array", items: { type: "integer" }, description: "Existing Epic IDs this child Job depends on." },
              depends_on: { type: "array", items: { type: "string" }, description: "Sibling job slugs this child depends on." }
            },
            required: %w[slug target_repo title description]
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
        return SyrusChatMcp.invalid("jobs must include at least one child Job") if job_attrs.empty?

        normalized_epic = normalize_epic(epic_attrs)
        normalized_jobs = job_attrs.map { |job| normalize_job(job) }
        validation_error = validate_payload(user, normalized_epic, normalized_jobs)
        return SyrusChatMcp.invalid(validation_error) if validation_error

        epic_repository = repository_for(user, chat_session, normalized_epic[:target_repo])
        return SyrusChatMcp.invalid("unknown epic target_repo: #{normalized_epic[:target_repo]}") unless epic_repository

        job_repositories = {}
        normalized_jobs.each do |job|
          repository = repository_for(user, chat_session, job[:target_repo])
          return SyrusChatMcp.invalid("unknown job target_repo for #{job[:slug]}: #{job[:target_repo]}") unless repository
          return SyrusChatMcp.invalid("job #{job[:slug]} target_repo must match the Epic target_repo") unless repository.id == epic_repository.id

          job_repositories[job[:slug]] = repository
        end

        proposal = nil
        ApplicationRecord.transaction do
          proposal = upsert_epic_proposal(chat_session, epic_repository, normalized_epic)
          child_by_slug = upsert_child_proposals(chat_session, proposal, job_repositories, normalized_jobs)
          replace_dependency_edges(child_by_slug, normalized_jobs)
          chat_session.messages.create!(
            role: "assistant",
            proposal: proposal,
            content: { "text" => "Epic proposal proposed." }
          )
        end

        SyrusChatMcp.success(payload_for(proposal.reload))
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def normalize_hash(value)
        value.to_h.transform_keys(&:to_s)
      end

      def normalize_epic(epic)
        {
          slug: epic["slug"].to_s.strip,
          title: epic["title"].to_s.strip,
          description: epic["description"].to_s.strip,
          target_repo: epic["target_repo"].to_s.strip,
          depends_on_job_ids: normalize_integer_list(epic["depends_on_job_ids"])
        }
      end

      def normalize_job(job)
        {
          slug: job["slug"].to_s.strip,
          title: job["title"].to_s.strip,
          description: job["description"].to_s.strip,
          target_repo: job["target_repo"].to_s.strip,
          depends_on_epic_ids: normalize_integer_list(job["depends_on_epic_ids"]),
          depends_on: normalize_string_list(job["depends_on"])
        }
      end

      def normalize_string_list(value)
        Array(value).map { |item| item.to_s.strip }.reject(&:empty?).uniq
      end

      def normalize_integer_list(value)
        Array(value).filter_map { |item| Integer(item, exception: false) }.uniq
      end

      def validate_payload(user, epic, jobs)
        return "epic slug is required" if epic[:slug].empty?
        return "epic title is required" if epic[:title].empty?
        return "epic description is required" if epic[:description].empty?

        slugs = jobs.map { |job| job[:slug] }
        return "child job slugs must be unique" if slugs.uniq.length != slugs.length
        return "epic slug must not duplicate a child job slug" if slugs.include?(epic[:slug])

        jobs.each do |job|
          return "job slug is required" if job[:slug].empty?
          return "job #{job[:slug]} title is required" if job[:title].empty?
          return "job #{job[:slug]} description is required" if job[:description].empty?
          return "job #{job[:slug]} target_repo is required" if job[:target_repo].empty?
          return "job #{job[:slug]} cannot depend on itself" if job[:depends_on].include?(job[:slug])
        end

        unknown = jobs.flat_map { |job| job[:depends_on] }.uniq - slugs
        return "unknown sibling depends_on slug(s): #{unknown.join(', ')}" if unknown.any?
        unknown_job_ids = epic[:depends_on_job_ids] - user.jobs.where(id: epic[:depends_on_job_ids]).pluck(:id)
        return "unknown epic depends_on_job_ids: #{unknown_job_ids.join(', ')}" if unknown_job_ids.any?
        unknown_epic_ids = jobs.flat_map { |job| job[:depends_on_epic_ids] }.uniq
        unknown_epic_ids -= user.epics.where(id: unknown_epic_ids).pluck(:id)
        return "unknown job depends_on_epic_ids: #{unknown_epic_ids.join(', ')}" if unknown_epic_ids.any?
        return "depends_on would create a cycle" if cyclic?(jobs)

        nil
      end

      def cyclic?(jobs)
        dependencies_by_slug = jobs.to_h { |job| [ job[:slug], job[:depends_on] ] }
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

      def repository_for(user, chat_session, slug)
        if slug.blank?
          repository = chat_session.repository
          return repository unless repository&.archived?

          return nil
        end

        owner, name = slug.split("/", 2)
        return nil if owner.blank? || name.blank?

        user.repositories.active.find_by(owner: owner, name: name)
      end

      def upsert_epic_proposal(chat_session, repository, epic)
        proposal = chat_session.proposals.find_or_initialize_by(slug: epic[:slug])
        proposal.assign_attributes(
          repository: repository,
          parent_proposal: nil,
          title: epic[:title],
          body: epic[:description],
          kind: "epic",
          labels: nil,
          depends_on_job_ids: epic[:depends_on_job_ids],
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
            state: "proposed",
            edited_at: child.persisted? ? Time.current : nil
          )
          child.save!
          child_by_slug[job[:slug]] = child
        end
        child_by_slug
      end

      def replace_dependency_edges(child_by_slug, jobs)
        child_by_slug.each_value { |proposal| proposal.dependency_edges.destroy_all }
        jobs.each do |job|
          proposal = child_by_slug.fetch(job[:slug])
          job[:depends_on].each do |dependency_slug|
            ChatProposalDependency.create!(
              proposal: proposal,
              depends_on: child_by_slug.fetch(dependency_slug)
            )
          end
        end
      end

      def payload_for(proposal)
        {
          id: proposal.id,
          slug: proposal.slug,
          state: proposal.state,
          kind: proposal.kind,
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
