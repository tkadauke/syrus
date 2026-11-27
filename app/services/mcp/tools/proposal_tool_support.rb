module Mcp::Tools
  module ProposalToolSupport
    PENDING_ACTION_CONTENTION_ERRORS = [
      ActiveRecord::LockWaitTimeout,
      ActiveRecord::Deadlocked,
      ActiveRecord::StatementTimeout
    ].freeze
    PENDING_ACTION_MAX_ATTEMPTS = 3
    PENDING_ACTION_RETRY_BASE_DELAY = 0.025

    private

    def normalize_string_list(value)
      Array(value).map { |item| item.to_s.strip }.reject(&:empty?).uniq
    end

    def normalize_integer_list(value)
      Array(value).filter_map { |item| Integer(item, exception: false) }.uniq
    end

    # Normalizes an optional implementing-provider override against the same
    # value set Jobs accept. Omitted and explicit "default" both resolve to
    # the "default" sentinel (current behavior: repository/user defaults win
    # at filing time). Returns [setting, nil] on success or [nil, error] for
    # an `invalid` tool rejection.
    def normalize_provider_setting(value)
      setting = value.to_s.strip.presence || Job::ProviderSetting::Base::DEFAULT_VALUE
      return [ setting, nil ] if Job::ProviderSetting::Base.values.include?(setting)

      [ nil, "unknown provider #{value.inspect}. Valid providers: #{Job::ProviderSetting::Base.values.join(', ')}" ]
    end

    # Models occasionally write JSON-style escape sequences into a tool-call
    # string instead of the character they actually intend -- the literal
    # two-character sequence backslash-n instead of an embedded newline, or a
    # backslash-escaped quote instead of a plain quote (an artifact of the
    # model composing the text as though it were about to be JSON-encoded
    # again). Proposal descriptions render as Markdown, so without this the
    # literal escape shows up verbatim instead of the intended character.
    def normalize_proposal_markdown(text)
      text.to_s
        .gsub('\n', "\n")
        .gsub("\\\"", "\"")
        .gsub("\\'", "'")
    end

    def explicit_planned_execution_capabilities?(planned_execution)
      return false unless planned_execution.respond_to?(:to_h)

      source = planned_execution.to_h.deep_stringify_keys
      raw_capabilities =
        if source.key?("capabilities")
          source["capabilities"]
        else
          source["planned_execution_capabilities"]
        end

      return false if raw_capabilities.blank?
      PlannedExecutionRequirement.normalize_capabilities(raw_capabilities).present?
    end

    def repository_for(chat_session, repo)
      token = repo.to_s.strip
      if token.blank?
        repository = chat_session.repository
        return repository unless repository&.archived?

        return nil
      end

      # Proposal targets may name another repo, but only from the current
      # user's active, membership-visible repository scope.
      scope = Repository.accessible_to(chat_session.user).active
      scope.find_by(id: Integer(token, exception: false)) ||
        scope.find_by(owner: token.split("/", 2).first, name: token.split("/", 2).second) ||
        scope.find_by(name: token)
    end

    def target_epic_for(chat_session, repository, epic_id)
      return if epic_id.blank?

      Epic.accessible_to(chat_session.user).where(repository: repository).find_by(id: epic_id)
    end

    def accessible_jobs_for(chat_session)
      Job.visible_to(chat_session.user)
    end

    def accessible_epics_for(chat_session)
      Epic.accessible_to(chat_session.user)
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

    def proposal_proposer(server_context)
      McpToolContext.from_server_context(server_context).agent_actor
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
      attempt = 0

      begin
        attempt += 1
        if (pending_action = reconciled_pending_action(server_context, chat_session, attributes))
          return pending_action
        end

        pending_action = nil
        ApplicationRecord.transaction do
          pending_action = chat_session.pending_actions.create!(**attributes)
          attach_pending_action_to_current_message!(server_context, pending_action)
        end
        pending_action
      rescue *PENDING_ACTION_CONTENTION_ERRORS => error
        log_pending_action_contention(error, server_context, chat_session, attributes, attempt)
        if attempt >= PENDING_ACTION_MAX_ATTEMPTS
          raise Mcp::Tools::TransientDatabaseContention, "pending action persistence remained contended"
        end

        sleep(pending_action_retry_delay(attempt)) unless Rails.env.test?
        retry
      end
    end

    def reconciled_pending_action(server_context, chat_session, attributes)
      message_id = server_context[:current_message]&.id
      return unless message_id

      pending_action_id = chat_session.messages.where(id: message_id).pick(:pending_action_id)
      return unless pending_action_id

      pending_action = chat_session.pending_actions.find_by(id: pending_action_id)
      return unless pending_action
      return unless pending_action.action == attributes[:action].to_s
      return unless pending_action.requested_by == attributes[:requested_by].to_s
      return unless pending_action.payload == attributes[:payload].deep_stringify_keys

      pending_action
    end

    def pending_action_retry_delay(attempt)
      base = PENDING_ACTION_RETRY_BASE_DELAY * (2**(attempt - 1))
      base + rand(0.0..base)
    end

    def log_pending_action_contention(error, server_context, chat_session, attributes, attempt)
      pool_diagnostics = ActiveRecord::Base.connection_pool.stat.slice(
        :size, :connections, :busy, :dead, :idle, :waiting, :checkout_timeout
      )
      Rails.logger.warn(
        "[Mcp::Tools::ProposalToolSupport] pending action contention " \
        "exception=#{error.class.name} action=#{attributes[:action]} chat_id=#{chat_session.id} " \
        "tool_call_id=#{attributes[:tool_use_id] || 'none'} " \
        "message_id=#{server_context[:current_message]&.id || 'none'} " \
        "attempt=#{attempt}/#{PENDING_ACTION_MAX_ATTEMPTS} pool=#{pool_diagnostics.inspect}"
      )
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
      ids - accessible_epics_for(chat_session).where(id: ids).pluck(:id)
    end

    def unknown_job_dependency_ids(chat_session, job_ids)
      ids = normalize_integer_list(job_ids)
      ids - accessible_jobs_for(chat_session).where(id: ids).pluck(:id)
    end

    def dependency_target_error(scope, ids)
      records_by_id = scope.where(id: ids).index_by(&:id)
      ids.each do |id|
        target = records_by_id[id]
        next unless target

        ProposalDependencyValidator.validate!(target)
      rescue ArgumentError => e
        return e.message
      end

      nil
    end

    def proposal_dependency_target_error(proposals)
      Array(proposals).each do |proposal|
        target = proposal.job || proposal.epic
        next unless target

        ProposalDependencyValidator.validate!(target)
      rescue ArgumentError => e
        return e.message
      end

      nil
    end
  end
end
