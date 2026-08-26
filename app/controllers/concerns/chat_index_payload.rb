# Chat index / recent-chats payload builders extracted from
# Api::V1::App::ChatsController.
#
# These assemble the sidebar's recent-chats list and the grouped chat index
# (General + one group per attached repository), including the keyset
# pagination cursor over the "pinned, then last-activity" ordering. They are
# pure controller helpers (reading `params` and `Current.user`, delegating to
# the controller's own helpers), so they
# mix straight back in with no behavior change. Kept private on include.
module ChatIndexPayload
  private

  CHAT_INDEX_GROUP_SIZE = 5

  def recent_chats_index_json
    PerformanceLogging.phase("chat_index.groups") do
      group_specs = PerformanceLogging.phase("chat_index.initial_groups") { initial_chat_index_group_specs }

      context = PerformanceLogging.phase("chat_index.context", count: group_specs.sum { |group| group.fetch(:chats).size }) do
        chat_index_context_for(group_specs.flat_map { |group| group.fetch(:chats) })
      end
      groups = group_specs.map { |group| chat_index_group_json(**group, context: context) }

      groups.sort_by { |group| group.delete(:active_at) || Time.at(0) }.reverse
    end
  end

  def supervisor_chat_index_json
    return unless Feature.admin_supervisor_chat_enabled?
    return unless Current.user.admin?

    chat_session = SupervisorChat.for_index(Current.user)
    chat_index_json(chat_session).merge(supervisor_unread_summary(chat_session))
  end

  def chat_index_group_json(key:, label:, repository_id:, chats:, has_more:, context: nil)
    PerformanceLogging.phase("chat_index.group.serialize", repository_id: repository_id, count: chats.size) do
      context ||= PerformanceLogging.phase("chat_index.group.context", repository_id: repository_id, count: chats.size) { chat_index_context_for(chats) }
      {
        key: key,
        label: label,
        repository_id: repository_id,
        chats: PerformanceLogging.phase("chat_index.group.chats", repository_id: repository_id, count: chats.size) do
          chats.map { |chat_session| chat_index_json(chat_session, context: context) }
        end,
        has_more: has_more,
        active_at: PerformanceLogging.phase("chat_index.group.active_at", repository_id: repository_id, count: chats.size) do
          chats.map { |chat_session| chat_activity_timestamp(chat_session) }.max
        end
      }
    end
  end

  def chat_index_json(chat_session, context: nil)
    PerformanceLogging.phase("chat_index.chat.serialize", chat_id: chat_session.id) do
      context ||= chat_index_context_for([ chat_session ])
      effective_provider = chat_session.effective_chat_provider
      repository = context.fetch(:repositories).fetch(chat_session.id, nil)

      {
        id: chat_session.id,
        title: chat_session.title.presence || ChatSession.fallback_title_for(repository),
        title_pending: chat_session.title.blank? && context.fetch(:title_pending_ids).include?(chat_session.id),
        system_kind: chat_session.system_kind,
        pinned: chat_session.pinned?,
        pinned_context: chat_session.pinned_context,
        chat_provider: chat_session.chat_provider,
        effective_chat_provider: effective_provider,
        effective_chat_provider_label: chat_provider_label(effective_provider),
        provider_availability: context.fetch(:provider_availability).fetch(effective_provider, nil),
        chat_provider_options: context.fetch(:chat_provider_options),
        chat_model: chat_session.chat_model,
        available_chat_models: context.fetch(:available_chat_models).fetch(effective_provider, []),
        mode: chat_session.mode,
        local_daemon_state: chat_session.local_daemon_state,
        local_daemon_repo: chat_session.local_daemon_repo,
        local_daemon_branch: chat_session.local_daemon_branch,
        chat_path: chat_path(chat_session),
        repository: repository ? repository_json(repository).merge(repository_path: repository_path(repository)) : nil,
        turn_in_flight: chat_session.turn_in_flight?,
        agent_busy: context.fetch(:agent_busy_ids).include?(chat_session.id),
        stop_requested_at: chat_session.stop_requested_at&.iso8601,
        suggested_next_step: chat_session.suggested_next_step,
        cumulative_input_tokens: chat_session.cumulative_input_tokens.to_i,
        cumulative_output_tokens: chat_session.cumulative_output_tokens.to_i,
        cumulative_cost_usd: chat_session.cumulative_cost.to_f,
        pending_proposal_count: context.fetch(:pending_proposal_counts).fetch(chat_session.id, 0),
        scratchpad_items_count: context.fetch(:scratchpad_counts).fetch(chat_session.id, 0),
        coding_checkout_uncommitted: chat_session.coding_checkout_uncommitted?,
        coding_checkout_branch: chat_session.coding_checkout_branch,
        chat_effort: chat_session.chat_effort,
        last_message_at: chat_session.last_message_at&.iso8601,
        unread: PerformanceLogging.phase("chat_index.chat.unread", chat_id: chat_session.id) { chat_unread?(chat_session) },
        created_at: chat_session.created_at.iso8601,
        updated_at: chat_session.updated_at.iso8601
      }
    end
  end

  def chat_index_context_for(chat_sessions)
    chat_sessions = Array(chat_sessions)
    ids = chat_sessions.map(&:id)
    blank_title_ids = chat_sessions.select { |chat_session| chat_session.title.blank? }.map(&:id)
    workdirs_by_id = chat_sessions.to_h { |chat_session| [ chat_session.id, chat_session.workspace_root.to_s ] }
    busy_workdirs = if workdirs_by_id.empty?
      []
    else
      SpawnedProcess.live_agent.where(workdir: workdirs_by_id.values).pluck(:workdir)
    end
    providers = chat_sessions.map(&:effective_chat_provider).compact.uniq

    {
      repositories: chat_sessions.to_h { |chat_session| [ chat_session.id, chat_session.repository ] },
      title_pending_ids: blank_title_ids.empty? ? [] : ChatMessage.where(chat_session_id: blank_title_ids, role: "user").distinct.pluck(:chat_session_id),
      agent_busy_ids: workdirs_by_id.select { |_id, workdir| busy_workdirs.include?(workdir) }.keys,
      pending_proposal_counts: chat_index_pending_proposal_counts(ids),
      scratchpad_counts: ids.empty? ? {} : ChatScratchpadItem.where(chat_session_id: ids).group(:chat_session_id).count,
      provider_availability: providers.to_h { |provider| [ provider, ::App::ProviderAvailability.for_user(Current.user, provider) ] },
      chat_provider_options: chat_provider_options(nil),
      available_chat_models: providers.to_h do |provider|
        representative = chat_sessions.find { |chat_session| chat_session.effective_chat_provider == provider }
        [ provider, representative ? available_chat_models_for(representative) : [] ]
      end
    }
  end

  def chat_index_pending_proposal_counts(chat_session_ids)
    return {} if chat_session_ids.empty?

    proposal_counts = ChatProposal.where(chat_session_id: chat_session_ids, state: "proposed").group(:chat_session_id).count
    pending_action_counts = ChatPendingAction.where(chat_session_id: chat_session_ids, state: "pending").group(:chat_session_id).count

    chat_session_ids.to_h do |chat_session_id|
      [
        chat_session_id,
        proposal_counts.fetch(chat_session_id, 0) + pending_action_counts.fetch(chat_session_id, 0)
      ]
    end
  end

  def paginated_chat_index_group(scope, before_chat: nil)
    PerformanceLogging.phase("chat_index.paginated_group", before_chat_id: before_chat&.id) do
      scope = chat_index_before(scope, before_chat) if before_chat
      fetched = scope.preload(:chat_participants, repository_attachments: :attachable).limit(CHAT_INDEX_GROUP_SIZE + 1).to_a
      [ fetched.first(CHAT_INDEX_GROUP_SIZE), fetched.size > CHAT_INDEX_GROUP_SIZE ]
    end
  end

  def initial_chat_index_group_specs
    rows = chat_index_initial_group_rows
    return [] if rows.empty?

    chat_ids = rows.map { |row| row.fetch("chat_session_id").to_i }.uniq
    repository_ids = rows.filter_map { |row| row.fetch("repository_id")&.to_i }.uniq
    chats_by_id = ChatSession.where(id: chat_ids)
      .preload(:chat_participants, repository_attachments: :attachable)
      .index_by(&:id)
    repositories_by_id = Current.user.repositories.where(id: repository_ids).index_by(&:id)

    rows.group_by { |row| row.fetch("repository_id")&.to_i }.filter_map do |repository_id, group_rows|
      ordered_rows = group_rows.sort_by { |row| row.fetch("group_position").to_i }
      chats = ordered_rows.first(CHAT_INDEX_GROUP_SIZE).filter_map { |row| chats_by_id[row.fetch("chat_session_id").to_i] }
      next if chats.empty?

      if repository_id
        repository = repositories_by_id[repository_id]
        next unless repository

        {
          key: "repository-#{repository.id}",
          label: repository.slug,
          repository_id: repository.id,
          chats: chats,
          has_more: ordered_rows.size > CHAT_INDEX_GROUP_SIZE
        }
      else
        {
          key: "general",
          label: "General",
          repository_id: nil,
          chats: chats,
          has_more: ordered_rows.size > CHAT_INDEX_GROUP_SIZE
        }
      end
    end
  end

  def chat_index_initial_group_rows
    ranked_scope = Current.user.accessible_chat_sessions
      .visible
      .active
      .ordinary_chats
      .left_outer_joins(:repository_attachments)
      .reselect(Arel.sql(<<~SQL.squish))
        chat_sessions.id AS chat_session_id,
        chat_attachments.attachable_id AS repository_id,
        ROW_NUMBER() OVER (
          PARTITION BY chat_attachments.attachable_id
          ORDER BY chat_sessions.pinned DESC, #{chat_activity_order_sql} DESC, chat_sessions.id DESC
        ) AS group_position
      SQL

    quoted_limit = ActiveRecord::Base.connection.quote(CHAT_INDEX_GROUP_SIZE + 1)
    ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
      SELECT chat_session_id, repository_id, group_position
      FROM (#{ranked_scope.to_sql}) chat_index_ranked
      WHERE group_position <= #{quoted_limit}
    SQL
  end

  def chat_index_before(scope, before_chat)
    timestamp = chat_activity_timestamp(before_chat)
    scope.where(
      "chat_sessions.pinned < ? OR (chat_sessions.pinned = ? AND ((#{chat_activity_order_sql}) < ? OR ((#{chat_activity_order_sql}) = ? AND chat_sessions.id < ?)))",
      before_chat.pinned? ? 1 : 0,
      before_chat.pinned? ? 1 : 0,
      timestamp,
      timestamp,
      before_chat.id
    )
  end

  def chat_index_group_scope(repository_id)
    scope = Current.user.accessible_chat_sessions
      .visible
      .active
      .ordinary_chats
      .left_outer_joins(:repository_attachments)
      .order(Arel.sql("chat_sessions.pinned DESC, #{chat_activity_order_sql} DESC, chat_sessions.id DESC"))

    if repository_id.present?
      scope.where(chat_attachments: { attachable_type: "Repository", attachable_id: repository_id })
    else
      scope.where(chat_attachments: { id: nil })
    end
  end

  def chat_index_repositories
    repository_ids = Current.user.accessible_chat_sessions
      .visible
      .active
      .ordinary_chats
      .joins(:repository_attachments)
      .where(chat_attachments: { attachable_type: "Repository" })
      .distinct
      .pluck("chat_attachments.attachable_id")

    Current.user.repositories.where(id: repository_ids).order(:owner, :name)
  end

  def chat_index_repository_id
    repository_id = params[:repository_id].to_s
    return nil if repository_id == "general"

    parsed = Integer(repository_id, exception: false)
    return parsed if parsed

    render_error("validation_failed", "repository_id is required.", status: :unprocessable_content)
    nil
  end

  def chat_activity_timestamp(chat_session)
    chat_activity_at(chat_session)
  end

  def chat_activity_order_sql
    "COALESCE(chat_sessions.last_message_at, chat_sessions.created_at)"
  end

  def chat_activity_at(chat_session)
    chat_session.last_message_at || chat_session.created_at
  end

  def supervisor_unread_summary(chat_session)
    last_read_at = current_participant_for(chat_session)&.last_read_at || chat_session.last_read_at

    unread_events = chat_session.scoped_events
    unread_events = unread_events.where("created_at > ?", last_read_at) if last_read_at.present?

    legacy_unread_messages = chat_session.messages.where(role: "system")
    legacy_unread_messages = legacy_unread_messages.where("created_at > ?", last_read_at) if last_read_at.present?

    severity_rank = { "info" => 0, "warning" => 1, "critical" => 2 }
    event_severities = unread_events.order(created_at: :desc, id: :desc).limit(200).pluck(:payload).filter_map do |payload|
      next unless payload.is_a?(Hash)

      severity = payload["severity"].to_s
      severity if severity_rank.key?(severity)
    end
    legacy_severities = legacy_unread_messages.order(created_at: :desc, id: :desc).limit(200).pluck(:content).filter_map do |content|
      next unless content.is_a?(Hash)
      next if content.dig("supervisor_event", "scoped_event_id").present?

      severity = content.dig("supervisor_event", "severity").to_s
      severity if severity_rank.key?(severity)
    end

    unread_count = unread_events.count + legacy_severities.size
    severities = event_severities + legacy_severities
    {
      unread: unread_count.positive? || (chat_unread?(chat_session) && chat_session.messages.exists?),
      supervisor_unread_count: unread_count,
      supervisor_unread_severity: severities.max_by { |severity| severity_rank.fetch(severity) }
    }
  end
end
