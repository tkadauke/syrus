module SyrusChatMcp
  module ProposalToolSupport
    private

    def normalize_string_list(value)
      Array(value).map { |item| item.to_s.strip }.reject(&:empty?).uniq
    end

    def normalize_integer_list(value)
      Array(value).filter_map { |item| Integer(item, exception: false) }.uniq
    end

    def repository_for(chat_session, repo)
      token = repo.to_s.strip
      if token.blank?
        repository = chat_session.repository
        return repository unless repository&.archived?

        return nil
      end

      # Proposal targets may name another repo, but only from the current
      # user's active repository scope.
      scope = chat_session.user.repositories.active
      scope.find_by(id: Integer(token, exception: false)) ||
        scope.find_by(owner: token.split("/", 2).first, name: token.split("/", 2).second) ||
        scope.find_by(name: token)
    end

    def target_epic_for(chat_session, repository, epic_id)
      return if epic_id.blank?

      chat_session.user.epics.where(repository: repository).find_by(id: epic_id)
    end

    def unique_slug(chat_session, title, prefix:)
      base = title.to_s.parameterize.presence || prefix
      base = "#{prefix}-#{base}" unless base.start_with?("#{prefix}-")
      slug = base.first(80)
      suffix = 2

      while chat_session.proposals.exists?(slug: slug)
        tail = "-#{suffix}"
        slug = "#{base.first(80 - tail.length)}#{tail}"
        suffix += 1
      end

      slug
    end

    def create_proposal_message!(chat_session, proposal, text:)
      chat_session.messages.create!(
        role: "assistant",
        proposal: proposal,
        content: { "text" => text }
      )
    end

    def attach_pending_action_to_current_message!(server_context, pending_action)
      if (msg = server_context[:current_message])
        ChatMessage.transaction do
          msg.chat_session.messages
            .where(pending_action_id: pending_action.id)
            .where.not(id: msg.id)
            .update_all(pending_action_id: nil)
          msg.update_columns(pending_action_id: pending_action.id)
        end
      end
    end

    def create_pending_action_for_current_message!(server_context, chat_session, **attributes)
      pending_action = nil
      ApplicationRecord.transaction do
        pending_action = chat_session.pending_actions.create!(**attributes)
        attach_pending_action_to_current_message!(server_context, pending_action)
      end
      pending_action
    end

    def dependency_proposals(chat_session, depends_on)
      dependency_slugs = normalize_string_list(depends_on)
      proposals_by_slug = chat_session.proposals.index_by(&:slug)
      unknown_slugs = dependency_slugs - proposals_by_slug.keys
      return [ nil, unknown_slugs ] if unknown_slugs.any?

      [ dependency_slugs.map { |slug| proposals_by_slug.fetch(slug) }, [] ]
    end

    def unknown_epic_dependency_ids(chat_session, epic_ids)
      ids = normalize_integer_list(epic_ids)
      ids - chat_session.user.epics.where(id: ids).pluck(:id)
    end

    def unknown_job_dependency_ids(chat_session, job_ids)
      ids = normalize_integer_list(job_ids)
      ids - chat_session.user.jobs.where(id: ids).pluck(:id)
    end
  end
end
