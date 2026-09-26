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
  CHAT_INDEX_STATUS_OPTIONS = %w[active hidden all].freeze
  CHAT_INDEX_GROUP_BY_OPTIONS = %w[date repository status mode].freeze
  CHAT_INDEX_SORT_BY_OPTIONS = %w[name date_created last_activity].freeze
  CHAT_INDEX_PER_GROUP_OPTIONS = [ 5, 10, 15, 20 ].freeze
  CHAT_INDEX_MODE_LABELS = {
    "planning" => "Planning",
    "coding" => "Coding",
    "local" => "Local"
  }.freeze

  private

  def validate_chat_index_settings
    chat_index_settings
    return true unless @chat_index_param_error

    render_error("validation_failed", @chat_index_param_error, status: :unprocessable_content)
    false
  end

  def chat_index_settings
    @chat_index_settings ||= begin
      status = chat_index_param(:status, CHAT_INDEX_STATUS_OPTIONS, "active")
      group_by = chat_index_param(:group_by, CHAT_INDEX_GROUP_BY_OPTIONS, "repository")
      sort_by = chat_index_param(:sort_by, CHAT_INDEX_SORT_BY_OPTIONS, "last_activity")
      per_group = Integer(params[:per_group], exception: false)
      if params.key?(:per_group) && !CHAT_INDEX_PER_GROUP_OPTIONS.include?(per_group)
        @chat_index_param_error ||= "per_group must be one of: #{CHAT_INDEX_PER_GROUP_OPTIONS.join(", ")}."
      end
      per_group = Current.user.recent_chats_group_size unless CHAT_INDEX_PER_GROUP_OPTIONS.include?(per_group)

      {
        status: status,
        group_by: group_by,
        sort_by: sort_by,
        per_group: per_group,
        show_empty_groups: group_by != "date" && ActiveModel::Type::Boolean.new.cast(params[:show_empty_groups])
      }
    end
  end

  def chat_index_param(name, allowed, fallback)
    value = params[name].to_s.presence || fallback
    return value if allowed.include?(value)

    @chat_index_param_error ||= "#{name} must be one of: #{allowed.join(", ")}."
    fallback
  end

  def chat_index_group_size
    chat_index_settings.fetch(:per_group)
  end

  def recent_chats_index_json
    PerformanceLogging.phase("chat_index.groups") do
      group_specs = PerformanceLogging.phase("chat_index.initial_groups") { initial_chat_index_group_specs }

      context = PerformanceLogging.phase("chat_index.context", count: group_specs.sum { |group| group.fetch(:chats).size }) do
        chat_index_context_for(group_specs.flat_map { |group| group.fetch(:chats) })
      end
      groups = group_specs.map { |group| chat_index_group_json(**group, context: context) }

      sort_chat_index_groups(groups)
    end
  end

  def chat_index_group_json(key:, label:, repository_id:, chats:, has_more:, group_by: nil, group_value: nil, context: nil)
    PerformanceLogging.phase("chat_index.group.serialize", repository_id: repository_id, count: chats.size) do
      context ||= PerformanceLogging.phase("chat_index.group.context", repository_id: repository_id, count: chats.size) { chat_index_context_for(chats) }
      {
        key: key,
        label: label,
        repository_id: repository_id,
        group_by: group_by || chat_index_settings.fetch(:group_by),
        group_value: group_value,
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
        active_goal: chat_goal_json(context.fetch(:active_goals).fetch(chat_session.id, nil)),
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
      Set.new
    else
      SpawnedProcess.live_agent.where(workdir: workdirs_by_id.values).pluck(:workdir).to_set
    end
    providers = chat_sessions.map(&:effective_chat_provider).compact.uniq

    {
      repositories: chat_sessions.to_h { |chat_session| [ chat_session.id, chat_session.repository ] },
      title_pending_ids: blank_title_ids.empty? ? [] : ChatMessage.where(chat_session_id: blank_title_ids, role: "user").distinct.pluck(:chat_session_id),
      agent_busy_ids: workdirs_by_id.select { |_id, workdir| busy_workdirs.include?(workdir) }.keys,
      pending_proposal_counts: chat_index_pending_proposal_counts(ids),
      scratchpad_counts: ids.empty? ? {} : ChatScratchpadItem.where(chat_session_id: ids).group(:chat_session_id).count,
      provider_availability: providers.to_h { |provider| [ provider, ::App::ProviderAvailability.for_user(Current.user, provider) ] },
      active_goals: visible_chat_goals_for(ids),
      chat_provider_options: chat_provider_options(nil),
      available_chat_models: providers.to_h do |provider|
        representative = chat_sessions.find { |chat_session| chat_session.effective_chat_provider == provider }
        [ provider, representative ? available_chat_models_for(representative) : [] ]
      end
    }
  end

  def visible_chat_goals_for(chat_session_ids)
    return {} if chat_session_ids.empty?

    active_by_chat_id = ChatGoal.where(chat_session_id: chat_session_ids, active_slot: ChatGoal::ACTIVE_SLOT).index_by(&:chat_session_id)
    fallback_ids = chat_session_ids - active_by_chat_id.keys
    return active_by_chat_id if fallback_ids.empty?

    latest_terminal_by_chat_id = latest_terminal_chat_goals_for(fallback_ids).index_by(&:chat_session_id)
    latest_terminal_by_chat_id.merge(active_by_chat_id)
  end

  def latest_terminal_chat_goals_for(chat_session_ids)
    return [] if chat_session_ids.empty?

    ranked_goals = ChatGoal.terminal.where(chat_session_id: chat_session_ids).select(
      "chat_goals.*, ROW_NUMBER() OVER (PARTITION BY chat_session_id ORDER BY created_at DESC, id DESC) AS syrus_goal_rank"
    )
    ChatGoal.from("(#{ranked_goals.to_sql}) chat_goals").where("syrus_goal_rank = 1")
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
      fetched = scope.preload(:chat_participants, repository_attachments: :attachable).limit(chat_index_group_size + 1).to_a
      [ fetched.first(chat_index_group_size), fetched.size > chat_index_group_size ]
    end
  end

  def initial_chat_index_group_specs
    rows = chat_index_initial_group_rows
    chat_ids = rows.map { |row| row.fetch("chat_session_id").to_i }.uniq
    repository_ids = rows.filter_map { |row| row.fetch("repository_id")&.to_i }.uniq
    chats_by_id = ChatSession.where(id: chat_ids)
      .preload(:chat_participants, repository_attachments: :attachable)
      .index_by(&:id)
    repositories_by_id = Current.user.repositories.where(id: repository_ids).index_by(&:id)
    grouped_rows = rows.group_by { |row| row.fetch("group_key").to_s }
    specs = grouped_rows.filter_map do |group_key, group_rows|
      ordered_rows = group_rows.sort_by { |row| row.fetch("group_position").to_i }
      chats = ordered_rows.first(chat_index_group_size).filter_map { |row| chats_by_id[row.fetch("chat_session_id").to_i] }
      spec = chat_index_group_spec_for(group_key, repository_id: group_rows.first["repository_id"]&.to_i, repositories_by_id: repositories_by_id)
      next unless spec

      spec.merge(
        chats: chats,
        has_more: ordered_rows.size > chat_index_group_size
      )
    end

    return specs unless chat_index_settings.fetch(:show_empty_groups)

    merge_empty_chat_index_group_specs(specs, repositories_by_id: repositories_by_id)
  end

  def chat_index_initial_group_rows
    ranked_scope = chat_index_base_scope
      .active
      .ordinary_chats
    ranked_scope = ranked_scope.left_outer_joins(:repository_attachments) if chat_index_settings.fetch(:group_by) == "repository"
    repository_id_sql = chat_index_settings.fetch(:group_by) == "repository" ? "chat_attachments.attachable_id" : "NULL"
    ranked_scope = ranked_scope
      .reselect(Arel.sql(<<~SQL.squish))
        chat_sessions.id AS chat_session_id,
        #{repository_id_sql} AS repository_id,
        #{chat_index_group_key_sql} AS group_key,
        ROW_NUMBER() OVER (
          PARTITION BY #{chat_index_group_key_sql}
          ORDER BY #{chat_index_order_sql}
        ) AS group_position
      SQL

    quoted_limit = ActiveRecord::Base.connection.quote(chat_index_group_size + 1)
    ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
      SELECT chat_session_id, repository_id, group_key, group_position
      FROM (#{ranked_scope.to_sql}) chat_index_ranked
      WHERE group_position <= #{quoted_limit}
    SQL
  end

  def chat_index_before(scope, before_chat)
    pinned_value = before_chat.pinned? ? 1 : 0
    scope.where(
      chat_index_cursor_predicate_sql,
      pinned_value,
      pinned_value,
      chat_index_cursor_value(before_chat),
      chat_index_cursor_value(before_chat),
      before_chat.id
    )
  end

  def chat_index_group_scope(group_by:, group_key:)
    scope = chat_index_base_scope
      .active
      .ordinary_chats
      .order(Arel.sql(chat_index_order_sql))
    scope = scope.left_outer_joins(:repository_attachments) if group_by == "repository"

    scope.where(chat_index_group_match_sql(group_by), group_key)
  end

  def chat_index_base_scope
    scope = Current.user.accessible_chat_sessions
    scope = case chat_index_settings.fetch(:status)
    when "hidden"
      scope.hidden
    when "all"
      scope
    else
      scope.visible
    end

    scope
  end

  def chat_index_group_spec_for(group_key, repository_id:, repositories_by_id:)
    group_by = chat_index_settings.fetch(:group_by)
    if group_by == "repository"
      if repository_id
        repository = repositories_by_id[repository_id]
        return unless repository

        return { key: "repository-#{repository.id}", label: repository.slug, repository_id: repository.id, group_by: group_by, group_value: repository.id.to_s }
      end

      return { key: "general", label: "General", repository_id: nil, group_by: group_by, group_value: "general" }
    end

    { key: "#{group_by}-#{group_key}", label: chat_index_group_label(group_by, group_key), repository_id: nil, group_by: group_by, group_value: group_key }
  end

  def merge_empty_chat_index_group_specs(specs, repositories_by_id:)
    existing_keys = specs.map { |spec| spec.fetch(:key) }.to_set
    empty_specs = chat_index_empty_group_specs(repositories_by_id: repositories_by_id).reject { |spec| existing_keys.include?(spec.fetch(:key)) }
    specs + empty_specs
  end

  def chat_index_empty_group_specs(repositories_by_id:)
    case chat_index_settings.fetch(:group_by)
    when "repository"
      repositories = Current.user.repositories.active.order(:owner, :name).to_a
      repository_specs = repositories.map do |repository|
        repositories_by_id[repository.id] ||= repository
        { key: "repository-#{repository.id}", label: repository.slug, repository_id: repository.id, group_by: "repository", group_value: repository.id.to_s, chats: [], has_more: false }
      end
      [ { key: "general", label: "General", repository_id: nil, group_by: "repository", group_value: "general", chats: [], has_more: false }, *repository_specs ]
    when "status"
      statuses = chat_index_settings.fetch(:status) == "all" ? %w[active hidden] : [ chat_index_settings.fetch(:status) ]
      statuses.map { |status| { key: "status-#{status}", label: chat_index_group_label("status", status), repository_id: nil, group_by: "status", group_value: status, chats: [], has_more: false } }
    when "mode"
      ChatSession::MODES.map { |mode| { key: "mode-#{mode}", label: chat_index_group_label("mode", mode), repository_id: nil, group_by: "mode", group_value: mode, chats: [], has_more: false } }
    else
      []
    end
  end

  def chat_index_group_label(group_by, group_key)
    case group_by
    when "date"
      chat_index_date_label(group_key)
    when "status"
      group_key == "hidden" ? "Hidden" : "Active"
    when "mode"
      CHAT_INDEX_MODE_LABELS.fetch(group_key, group_key.to_s.titleize)
    else
      group_key
    end
  end

  def chat_index_date_label(group_key)
    date = Date.iso8601(group_key)
    today = Time.zone.today
    return "Today" if date == today
    return "Yesterday" if date == today - 1

    date.strftime("%b %-d, %Y")
  rescue ArgumentError
    group_key
  end

  def sort_chat_index_groups(groups)
    sorted = case chat_index_settings.fetch(:group_by)
    when "repository"
      groups.sort_by { |group| [ group.fetch(:chats).empty? ? 1 : 0, -(group.delete(:active_at)&.to_i || 0), group.fetch(:label).downcase ] }
    when "status"
      order = { "status-active" => 0, "status-hidden" => 1 }
      groups.sort_by { |group| [ order.fetch(group.fetch(:key), 9), group.fetch(:chats).empty? ? 1 : 0 ] }
    when "mode"
      order = ChatSession::MODES.each_with_index.to_h { |mode, index| [ "mode-#{mode}", index ] }
      groups.sort_by { |group| [ order.fetch(group.fetch(:key), 9), group.fetch(:chats).empty? ? 1 : 0 ] }
    else
      groups.sort_by { |group| group.fetch(:key) }.reverse
    end
    sorted.each { |group| group.delete(:active_at) }
  end

  def chat_index_group_key_sql
    {
      "date" => "DATE(#{chat_activity_order_sql})",
      "repository" => "COALESCE(CAST(chat_attachments.attachable_id AS CHAR), 'general')",
      "status" => "CASE WHEN chat_sessions.hidden_at IS NULL THEN 'active' ELSE 'hidden' END",
      "mode" => "COALESCE(chat_sessions.mode, 'planning')"
    }.fetch(chat_index_settings.fetch(:group_by))
  end

  def chat_index_group_match_sql(group_by)
    {
      "date" => "DATE(#{chat_activity_order_sql}) = ?",
      "repository" => "COALESCE(CAST(chat_attachments.attachable_id AS CHAR), 'general') = ?",
      "status" => "CASE WHEN chat_sessions.hidden_at IS NULL THEN 'active' ELSE 'hidden' END = ?",
      "mode" => "COALESCE(chat_sessions.mode, 'planning') = ?"
    }.fetch(group_by)
  end

  def chat_index_order_sql
    "chat_sessions.pinned DESC, #{chat_index_sort_sql}, chat_sessions.id DESC"
  end

  def chat_index_sort_sql
    {
      "last_activity" => "#{chat_activity_order_sql} DESC",
      "date_created" => "chat_sessions.created_at DESC",
      "name" => "LOWER(COALESCE(NULLIF(chat_sessions.title, ''), '')) ASC"
    }.fetch(chat_index_settings.fetch(:sort_by))
  end

  def chat_index_cursor_predicate_sql
    {
      "last_activity" => "chat_sessions.pinned < ? OR (chat_sessions.pinned = ? AND ((#{chat_activity_order_sql}) < ? OR ((#{chat_activity_order_sql}) = ? AND chat_sessions.id < ?)))",
      "date_created" => "chat_sessions.pinned < ? OR (chat_sessions.pinned = ? AND (chat_sessions.created_at < ? OR (chat_sessions.created_at = ? AND chat_sessions.id < ?)))",
      "name" => "chat_sessions.pinned < ? OR (chat_sessions.pinned = ? AND (LOWER(COALESCE(NULLIF(chat_sessions.title, ''), '')) > ? OR (LOWER(COALESCE(NULLIF(chat_sessions.title, ''), '')) = ? AND chat_sessions.id < ?)))"
    }.fetch(chat_index_settings.fetch(:sort_by))
  end

  def chat_index_cursor_value(chat_session)
    {
      "last_activity" => chat_activity_timestamp(chat_session),
      "date_created" => chat_session.created_at,
      "name" => chat_session.title.to_s.downcase
    }.fetch(chat_index_settings.fetch(:sort_by))
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
end
