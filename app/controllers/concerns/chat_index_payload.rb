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
  CHAT_INDEX_GROUP_BY_OPTIONS = %w[date repository status mode chat_type agent].freeze
  CHAT_INDEX_SORT_BY_OPTIONS = %w[name date_created last_activity].freeze
  CHAT_INDEX_PER_GROUP_OPTIONS = [ 5, 10, 15, 20 ].freeze
  CHAT_INDEX_CHAT_TYPE_OPTIONS = %w[agent group external].freeze
  CHAT_INDEX_CHAT_TYPE_LABELS = {
    "agent" => "Agent chats",
    "group" => "Group chats",
    "external" => "External chats"
  }.freeze
  CHAT_INDEX_GROUP_PAGE_SIZE = 8
  CHAT_INDEX_INITIAL_GROUP_SIZE = 5
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
      group_by = "repository" if group_by == "chat_type" && !chat_type_feature_visible?
      group_by = "repository" if group_by == "agent" && !chat_agent_feature_visible?
      chat_types = chat_index_chat_types_param
      sort_by = chat_index_param(:sort_by, CHAT_INDEX_SORT_BY_OPTIONS, "last_activity")
      per_group = Integer(params[:per_group], exception: false)
      if params.key?(:per_group) && !CHAT_INDEX_PER_GROUP_OPTIONS.include?(per_group)
        @chat_index_param_error ||= "per_group must be one of: #{CHAT_INDEX_PER_GROUP_OPTIONS.join(", ")}."
      end
      per_group = Current.user.recent_chats_group_size unless CHAT_INDEX_PER_GROUP_OPTIONS.include?(per_group)
      group_offset = Integer(params[:group_offset], exception: false)
      if params.key?(:group_offset) && (!group_offset || group_offset.negative?)
        @chat_index_param_error ||= "group_offset must be a non-negative integer."
      end
      group_offset = 0 unless group_offset && group_offset >= 0

      {
        status: status,
        group_by: group_by,
        chat_types: chat_types,
        apply_chat_type_filter: chat_type_feature_visible? || params.key?(:chat_types),
        sort_by: sort_by,
        per_group: per_group,
        group_offset: group_offset,
        unread_only: ActiveModel::Type::Boolean.new.cast(params[:unread_only]),
        active_chat_id: Integer(params[:active_chat_id], exception: false),
        show_empty_groups: group_by != "date" && ActiveModel::Type::Boolean.new.cast(params[:show_empty_groups])
      }
    end
  end

  def chat_index_param(name, allowed, fallback)
    allowed = allowed + [ "shared", "plugin" ] if name == :group_by && action_name == "more"
    value = params[name].to_s.presence || fallback
    return value if allowed.include?(value)

    @chat_index_param_error ||= "#{name} must be one of: #{allowed.join(", ")}."
    fallback
  end

  def chat_index_group_size
    requested_size = chat_index_settings.fetch(:per_group)
    return requested_size unless action_name == "index" && chat_index_group_offset.zero?

    [ requested_size, CHAT_INDEX_INITIAL_GROUP_SIZE ].min
  end

  def chat_index_available_chat_types
    @chat_index_available_chat_types ||= Rails.cache.fetch(chat_index_option_cache_key("chat_types"), expires_in: 3.minutes) do
      options = [ "agent" ]
      options << "group" if User.count > 1
      options << "external" if chat_index_external_chat_type_available?
      options
    end
  end

  def chat_type_feature_visible?
    chat_index_available_chat_types.size > 1
  end

  def chat_index_available_agents
    @chat_index_available_agents ||= Rails.cache.fetch(chat_index_option_cache_key("agents"), expires_in: 3.minutes) do
      User.chat_providers.filter_map do |provider|
        next unless Current.user.chat_provider_configured?(provider)

        {
          value: provider,
          label: chat_provider_label(provider)
        }
      end
    end
  end

  def chat_index_option_cache_key(option)
    [ "chat-index-options", option, Current.user.cache_key_with_version ]
  end

  def chat_agent_feature_visible?
    chat_index_available_agents.size > 1
  end

  def chat_index_chat_types_param
    available = chat_index_available_chat_types
    values = Array(params[:chat_types]).flat_map { |value| value.to_s.split(",") }.map(&:presence).compact.uniq
    return available if values.empty?

    invalid = values - CHAT_INDEX_CHAT_TYPE_OPTIONS
    if invalid.any?
      @chat_index_param_error ||= "chat_types must contain only: #{CHAT_INDEX_CHAT_TYPE_OPTIONS.join(", ")}."
      return available
    end

    selected = values & available
    selected.presence || available
  end

  def chat_index_group_offset
    chat_index_settings.fetch(:group_offset)
  end

  def recent_chats_index_json
    PerformanceLogging.phase("chat_index.groups") do
      group_specs = PerformanceLogging.phase("chat_index.initial_groups") { initial_chat_index_group_specs }

      context = PerformanceLogging.phase("chat_index.context", count: group_specs.sum { |group| group.fetch(:chats).size }) do
        chat_index_context_for(group_specs.flat_map { |group| group.fetch(:chats) })
      end
      groups = group_specs.map { |group| chat_index_group_json(**group, context: context) }

      {
        groups: sort_chat_index_groups(groups),
        has_more: @chat_index_groups_has_more == true,
        next_offset: @chat_index_groups_has_more == true ? chat_index_group_offset + CHAT_INDEX_GROUP_PAGE_SIZE : nil,
        agent_appearances: chat_nav_agent_appearances(group_specs.flat_map { |group| group.fetch(:chats) }),
        provider_availability: chat_nav_provider_availability(group_specs.flat_map { |group| group.fetch(:chats) })
      }
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
          chats.map { |chat_session| chat_nav_json(chat_session, context: context) }
        end,
        has_more: has_more,
        active_at: PerformanceLogging.phase("chat_index.group.active_at", repository_id: repository_id, count: chats.size) do
          chats.map { |chat_session| chat_activity_timestamp(chat_session) }.max
        end
      }
    end
  end

  def chat_nav_json(chat_session, context: nil)
    PerformanceLogging.phase("chat_index.chat.serialize", chat_id: chat_session.id) do
      context ||= chat_index_context_for([ chat_session ])
      repository = context.fetch(:repositories).fetch(chat_session.id, nil)

      {
        id: chat_session.id,
        current_user_id: Current.user.id,
        user_id: chat_session.user_id,
        title: chat_session.title.presence || ChatSession.fallback_title_for(repository),
        title_pending: chat_session.title.blank? && context.fetch(:title_pending_ids).include?(chat_session.id),
        pinned: chat_session.pinned?,
        effective_chat_provider: chat_session.effective_chat_provider,
        conversation_kind: chat_session.conversation_kind,
        mode: chat_session.mode,
        chat_path: chat_path(chat_session),
        repository: repository ? repository_json(repository).merge(repository_path: repository_path(repository)) : nil,
        turn_in_flight: chat_session.turn_in_flight?,
        agent_busy: context.fetch(:agent_busy_ids).include?(chat_session.id),
        active_goal: chat_nav_goal_json(context.fetch(:active_goals).fetch(chat_session.id, nil)),
        pending_proposal_count: context.fetch(:pending_proposal_counts).fetch(chat_session.id, 0),
        scratchpad_items_count: context.fetch(:scratchpad_counts).fetch(chat_session.id, 0),
        job_summary: context.fetch(:job_summaries).fetch(chat_session.id, { active_count: 0, outcome: nil, jobs: [], epics: {} }),
        coding_checkout_uncommitted: chat_session.coding_checkout_uncommitted?,
        last_message_at: chat_session.last_message_at&.iso8601,
        created_at: chat_session.created_at.iso8601,
        # Both are needed by the client-side cache filter, which derives a
        # chat's type when it patches a row optimistically. Without them an
        # external chat whose conversation_kind is "group" derives as "group"
        # and lands in the wrong sidebar group until the next refetch. They are
        # two scalars off a row already loaded, so neither costs a query.
        origin_platform: chat_session.origin_platform,
        chat_type: chat_index_chat_type_for(chat_session),
        unread: PerformanceLogging.phase("chat_index.chat.unread", chat_id: chat_session.id) { chat_unread?(chat_session) }
      }
    end
  end

  def chat_nav_goal_json(goal)
    goal && { id: goal.id, status: goal.status }
  end

  def chat_created_payload(chat_session, message:)
    context = chat_index_context_for([ chat_session ])
    {
      message: message,
      redirect_to: chat_path(chat_session),
      chat: chat_nav_json(chat_session, context: context),
      agent_appearances: chat_nav_agent_appearances([ chat_session ])
    }
  end

  # Availability keyed by provider for the providers the listed chats use, so
  # slim nav rows do not repeat it per row and bootstrap stays slim.
  def chat_nav_provider_availability(chat_sessions)
    providers = Array(chat_sessions).filter_map(&:effective_chat_provider).uniq
    return {} if providers.empty?

    # One evidence batch for every provider, not one scan per provider.
    ::App::ProviderAvailability.all_for_user(Current.user).slice(*providers)
  end

  def chat_nav_agent_appearances(chat_sessions)
    Array(chat_sessions).filter_map do |chat_session|
      appearance = plugin_chat_metadata.dig(chat_session.id, :agent_appearance)
      [ chat_session.id, appearance ] if appearance
    end.to_h
  end

  def chat_index_context_for(chat_sessions)
    chat_sessions = Array(chat_sessions)
    ids = chat_sessions.map(&:id)
    blank_title_ids = chat_sessions.select { |chat_session| chat_session.title.blank? }.map(&:id)
    workdirs_by_id = chat_sessions.to_h { |chat_session| [ chat_session.id, chat_session.workspace_root.to_s ] }
    busy_agent_scope = SpawnedProcess.live_agent
    busy_agent_rows = if ids.empty? && workdirs_by_id.empty?
      []
    else
      busy_agent_scope
        .where(chat_session_id: ids)
        .or(busy_agent_scope.where(workdir: workdirs_by_id.values))
        .pluck(:chat_session_id, :workdir)
    end
    busy_ids = busy_agent_rows.filter_map { |chat_id, _workdir| chat_id }.to_set
    busy_workdirs = busy_agent_rows.filter_map { |_chat_id, workdir| workdir }.to_set
    {
      repositories: chat_sessions.to_h { |chat_session| [ chat_session.id, chat_session.repository ] },
      title_pending_ids: blank_title_ids.empty? ? [] : ChatMessage.where(chat_session_id: blank_title_ids, role: "user").distinct.pluck(:chat_session_id),
      agent_busy_ids: workdirs_by_id.filter_map { |id, workdir| id if busy_ids.include?(id) || busy_workdirs.include?(workdir) },
      pending_proposal_counts: chat_index_pending_proposal_counts(ids),
      scratchpad_counts: ids.empty? ? {} : ChatScratchpadItem.where(chat_session_id: ids).group(:chat_session_id).count,
      job_summaries: ChatJobSummary.for(chat_sessions: chat_sessions, user: Current.user),
      active_goals: visible_chat_goals_for(ids)
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
      fetched = scope.preload(*chat_repository_preloads).limit(chat_index_group_size + 1).to_a
      [ fetched.first(chat_index_group_size), fetched.size > chat_index_group_size ]
    end
  end

  def initial_chat_index_group_specs
    group_page = chat_index_group_page
    @chat_index_groups_has_more = group_page.fetch(:has_more)
    page_keys = group_page.fetch(:keys)
    special_specs = chat_index_group_offset.zero? ? shared_chat_group_specs + plugin_chat_group_specs : []
    if page_keys.empty? && chat_index_settings.fetch(:show_empty_groups) && chat_index_group_offset.zero?
      return special_specs + chat_index_empty_group_specs(repositories_by_id: {})
    end
    return special_specs if page_keys.empty?

    if chat_index_settings.fetch(:group_by) == "date"
      zone = ActiveSupport::TimeZone[Current.user.time_zone]
      first_date = Date.iso8601(page_keys.last)
      last_date = Date.iso8601(page_keys.first)
      start_at = zone.local(first_date.year, first_date.month, first_date.day)
      end_date = last_date.next_day
      end_at = zone.local(end_date.year, end_date.month, end_date.day)
      chats_by_date = chat_index_base_scope.active.ordinary_chats
        .where("#{chat_activity_order_sql} >= ? AND #{chat_activity_order_sql} < ?", start_at, end_at)
        .order(Arel.sql(chat_index_order_sql))
        .preload(*chat_repository_preloads)
        .group_by { |chat| chat_activity_at(chat).in_time_zone(zone).to_date.iso8601 }
      return special_specs + page_keys.map do |group_key|
        group_chats = chats_by_date.fetch(group_key, [])
        chat_index_group_spec_for(group_key, repository_id: nil, repositories_by_id: {}).merge(
          chats: group_chats.first(chat_index_group_size),
          has_more: group_chats.size > chat_index_group_size
        )
      end
    end

    rows = chat_index_initial_group_rows
    chat_ids = rows.map { |row| row.fetch("chat_session_id").to_i }.uniq
    repository_ids = rows.filter_map { |row| row.fetch("repository_id")&.to_i }.uniq
    chats_by_id = ChatSession.where(id: chat_ids)
      .preload(*chat_repository_preloads)
      .index_by(&:id)
    repositories_by_id = invocation_scoped_repository_scope(Repository.accessible_to(Current.user)).where(id: repository_ids).index_by(&:id)
    missing_repository_ids = repository_ids - repositories_by_id.keys
    repositories_by_id.merge!(Repository.where(id: missing_repository_ids).index_by(&:id)) if missing_repository_ids.any?
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

    specs = special_specs + specs
    return specs unless chat_index_settings.fetch(:show_empty_groups) && chat_index_group_offset.zero?

    merge_empty_chat_index_group_specs(specs, repositories_by_id: repositories_by_id)
  end

  def chat_repository_preloads
    preloads = [ :chat_participants, { repository_attachments: :attachable } ]
    preloads << { coworker_chat: :coworker } if ChatSession.reflect_on_association(:coworker_chat)
    preloads
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

    group_keys = chat_index_group_page.fetch(:keys)
    quoted_group_keys = group_keys.map { |key| ActiveRecord::Base.connection.quote(key) }.join(", ")
    quoted_limit = ActiveRecord::Base.connection.quote(chat_index_group_size + 1)
    ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
      SELECT chat_session_id, repository_id, group_key, group_position
      FROM (#{ranked_scope.to_sql}) chat_index_ranked
      WHERE group_position <= #{quoted_limit}
        AND group_key IN (#{quoted_group_keys})
    SQL
  end

  def chat_index_group_page
    @chat_index_group_page ||= begin
      date_grouping = chat_index_settings.fetch(:group_by) == "date"
      keys = if date_grouping
        chat_index_base_scope.active.ordinary_chats
          .pluck(:last_message_at, :created_at)
          .map { |last_message_at, created_at| (last_message_at || created_at).in_time_zone(Current.user.time_zone).to_date.iso8601 }
          .uniq
          .sort
          .reverse
      else
        ActiveRecord::Base.connection.select_all(chat_index_group_page_sql).map { |row| row.fetch("group_key").to_s }
      end
      page = (date_grouping ? keys.drop(chat_index_group_offset) : keys).first(CHAT_INDEX_GROUP_PAGE_SIZE + 1)
      limited_keys = page.first(CHAT_INDEX_GROUP_PAGE_SIZE)
      {
        keys: limited_keys,
        has_more: page.size > CHAT_INDEX_GROUP_PAGE_SIZE
      }
    end
  end

  def chat_index_group_page_sql
    grouped_scope = chat_index_base_scope
      .active
      .ordinary_chats
    grouped_scope = grouped_scope.left_outer_joins(:repository_attachments) if chat_index_settings.fetch(:group_by) == "repository"
    grouped_scope = grouped_scope
      .reselect(Arel.sql(<<~SQL.squish))
        #{chat_index_group_key_sql} AS group_key,
        MAX(#{chat_activity_order_sql}) AS active_at
      SQL
      .group(Arel.sql(chat_index_group_key_sql))
      .order(Arel.sql(chat_index_group_page_order_sql))
      .limit(CHAT_INDEX_GROUP_PAGE_SIZE + 1)
      .offset(chat_index_group_offset)

    grouped_scope.to_sql
  end

  def chat_index_group_page_order_sql
    case chat_index_settings.fetch(:group_by)
    when "date"
      "group_key DESC"
    when "repository"
      "active_at DESC, group_key ASC"
    when "status"
      "CASE group_key WHEN 'active' THEN 0 WHEN 'hidden' THEN 1 ELSE 9 END ASC"
    when "mode"
      mode_order = ChatSession::MODES.each_with_index.map do |mode, index|
        "WHEN #{ActiveRecord::Base.connection.quote(mode)} THEN #{index}"
      end.join(" ")
      "CASE group_key #{mode_order} ELSE 9 END ASC"
    when "chat_type"
      chat_type_order = CHAT_INDEX_CHAT_TYPE_OPTIONS.each_with_index.map do |chat_type, index|
        "WHEN #{ActiveRecord::Base.connection.quote(chat_type)} THEN #{index}"
      end.join(" ")
      "CASE group_key #{chat_type_order} ELSE 9 END ASC"
    when "agent"
      agent_order = chat_index_available_agents.each_with_index.map do |agent, index|
        "WHEN #{ActiveRecord::Base.connection.quote(agent.fetch(:value))} THEN #{index}"
      end.join(" ")
      "CASE group_key #{agent_order} ELSE 9 END ASC"
    else
      "group_key ASC"
    end
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
    return chat_index_shared_scope if group_by == "shared" && group_key == "shared-with-me"
    if group_by == "plugin"
      group = plugin_chat_list_groups.find { |candidate| candidate.fetch(:key) == group_key }
      return ChatSession.none unless group

      return plugin_chat_group_scope(group)
    end

    scope = chat_index_base_scope
      .active
      .ordinary_chats
      .order(Arel.sql(chat_index_order_sql))
    scope = scope.left_outer_joins(:repository_attachments) if group_by == "repository"

    if group_by == "date"
      date = Date.iso8601(group_key)
      zone = ActiveSupport::TimeZone[Current.user.time_zone]
      start_at = zone.local(date.year, date.month, date.day)
      end_at = zone.local(date.next_day.year, date.next_day.month, date.next_day.day)
      return scope.where("#{chat_activity_order_sql} >= ? AND #{chat_activity_order_sql} < ?", start_at, end_at)
    end

    scope.where(chat_index_group_match_sql(group_by), group_key)
  end

  def chat_index_base_scope
    chat_index_filtered_scope
      .where.not(id: plugin_chat_session_ids)
  end

  def chat_index_filtered_scope
    scope = invocation_scoped_chat_scope(Current.user.accessible_chat_sessions)
      .where.not(id: Current.user.received_chat_shares.select(:chat_session_id))
    scope = case chat_index_settings.fetch(:status)
    when "hidden"
      scope.where.not(chat_participants: { hidden_at: nil })
    when "all"
      scope
    else
      scope.where(chat_participants: { hidden_at: nil })
    end

    if chat_index_settings.fetch(:unread_only)
      active_chat_id = chat_index_settings.fetch(:active_chat_id)
      scope = if active_chat_id
        scope.where("(#{chat_index_unread_sql}) OR chat_sessions.id = ?", active_chat_id)
      else
        scope.where(chat_index_unread_sql)
      end
    end

    return scope unless chat_index_settings.fetch(:apply_chat_type_filter)

    scope.where("#{chat_index_chat_type_sql} IN (?)", chat_index_settings.fetch(:chat_types))
  end

  def shared_chat_group_specs
    scope = chat_index_shared_scope
    chats, has_more = paginated_chat_index_group(scope)
    return [] if chats.empty?

    [ {
      key: "shared-with-me",
      label: I18n.t("api.chats.groups.shared_with_me"),
      repository_id: nil,
      group_by: "shared",
      group_value: "shared-with-me",
      chats: chats,
      has_more: has_more
    } ]
  end

  def plugin_chat_group_specs
    plugin_chat_list_groups.filter_map do |group|
      chats, has_more = paginated_chat_index_group(plugin_chat_group_scope(group))
      next if chats.empty?

      {
        key: group.fetch(:key),
        label: group.fetch(:label),
        repository_id: nil,
        group_by: "plugin",
        group_value: group.fetch(:key),
        chats: chats,
        has_more: has_more
      }
    end
  end

  def plugin_chat_group_scope(group)
    chat_index_filtered_scope
      .where.not(id: Current.user.received_chat_shares.select(:chat_session_id))
      .where(id: group.fetch(:chat_session_ids))
      .active
      .ordinary_chats
      .order(Arel.sql(chat_index_order_sql))
  end

  def plugin_chat_session_ids
    plugin_chat_list_groups.flat_map { |group| group.fetch(:chat_session_ids) }.uniq
  end

  def plugin_chat_list_groups
    @plugin_chat_list_groups ||= begin
      claimed_ids = Set.new
      Syrus::PluginRegistry.providers_for(:chat_list_group).filter_map do |provider|
        contribution = provider.chat_list_group(user: Current.user)
        next if contribution.blank?

        key = contribution.fetch(:key).to_s
        label = contribution.fetch(:label).to_s
        ids = Array(contribution.fetch(:chat_session_ids)).filter_map { |id| Integer(id, exception: false) }.uniq
        next if key.blank? || label.blank? || ids.empty?

        ids.reject! { |id| claimed_ids.include?(id) }
        claimed_ids.merge(ids)
        next if ids.empty?

        metadata = contribution[:metadata_by_chat_session_id].to_h.transform_keys(&:to_i).slice(*ids)
        { key: key, label: label, chat_session_ids: ids, metadata_by_chat_session_id: metadata }
      end
    end
  end

  def plugin_chat_metadata
    @plugin_chat_metadata ||= plugin_chat_list_groups.each_with_object({}) do |group, result|
      result.merge!(group.fetch(:metadata_by_chat_session_id, {}))
    end
  end

  def chat_index_shared_scope
    invocation_scoped_chat_scope(Current.user.accessible_chat_sessions)
      .where(id: Current.user.received_chat_shares.select(:chat_session_id))
      .active
      .ordinary_chats
      .order(Arel.sql(chat_index_order_sql))
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
      repositories = invocation_scoped_repository_scope(Repository.accessible_to(Current.user)).active.order(:owner, :name).to_a
      repository_specs = repositories.map do |repository|
        repositories_by_id[repository.id] ||= repository
        { key: "repository-#{repository.id}", label: repository.slug, repository_id: repository.id, group_by: "repository", group_value: repository.id.to_s, chats: [], has_more: false }
      end
      [ { key: "general", label: "General", repository_id: nil, group_by: "repository", group_value: "general", chats: [], has_more: false }, *repository_specs ]
    when "status"
      statuses = chat_index_empty_status_groups
      statuses.map { |status| { key: "status-#{status}", label: chat_index_group_label("status", status), repository_id: nil, group_by: "status", group_value: status, chats: [], has_more: false } }
    when "mode"
      ChatSession::MODES.map { |mode| { key: "mode-#{mode}", label: chat_index_group_label("mode", mode), repository_id: nil, group_by: "mode", group_value: mode, chats: [], has_more: false } }
    when "chat_type"
      chat_index_settings.fetch(:chat_types).map do |chat_type|
        { key: "chat_type-#{chat_type}", label: chat_index_group_label("chat_type", chat_type), repository_id: nil, group_by: "chat_type", group_value: chat_type, chats: [], has_more: false }
      end
    when "agent"
      chat_index_available_agents.map do |agent|
        value = agent.fetch(:value)
        { key: "agent-#{value}", label: agent.fetch(:label), repository_id: nil, group_by: "agent", group_value: value, chats: [], has_more: false }
      end
    else
      []
    end
  end

  def chat_index_group_label(group_by, group_key)
    case group_by
    when "date"
      chat_index_date_label(group_key)
    when "status"
      { "unread" => "Unread", "hidden" => "Hidden", "active" => "Active" }.fetch(group_key, group_key.to_s.titleize)
    when "mode"
      CHAT_INDEX_MODE_LABELS.fetch(group_key, group_key.to_s.titleize)
    when "chat_type"
      CHAT_INDEX_CHAT_TYPE_LABELS.fetch(group_key, group_key.to_s.titleize)
    when "agent"
      chat_index_available_agents.find { |agent| agent.fetch(:value) == group_key }&.fetch(:label) || chat_provider_label(group_key)
    else
      group_key
    end
  end

  def chat_index_date_label(group_key)
    date = Date.iso8601(group_key)
    today = Time.current.in_time_zone(Current.user.time_zone).to_date
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
      order = { "status-unread" => 0, "status-active" => 1, "status-hidden" => 2 }
      groups.sort_by { |group| [ order.fetch(group.fetch(:key), 9), group.fetch(:chats).empty? ? 1 : 0 ] }
    when "mode"
      order = ChatSession::MODES.each_with_index.to_h { |mode, index| [ "mode-#{mode}", index ] }
      groups.sort_by { |group| [ order.fetch(group.fetch(:key), 9), group.fetch(:chats).empty? ? 1 : 0 ] }
    when "chat_type"
      order = CHAT_INDEX_CHAT_TYPE_OPTIONS.each_with_index.to_h { |chat_type, index| [ "chat_type-#{chat_type}", index ] }
      groups.sort_by { |group| [ order.fetch(group.fetch(:key), 9), group.fetch(:chats).empty? ? 1 : 0 ] }
    when "agent"
      order = chat_index_available_agents.each_with_index.to_h { |agent, index| [ "agent-#{agent.fetch(:value)}", index ] }
      groups.sort_by { |group| [ order.fetch(group.fetch(:key), 9), group.fetch(:chats).empty? ? 1 : 0 ] }
    else
      groups.sort_by { |group| group.fetch(:key) }.reverse
    end
    sorted = sorted.sort_by do |group|
      if group.fetch(:key) == "shared-with-me"
        0
      elsif group[:group_by] == "plugin"
        1
      else
        2
      end
    end
    sorted.each { |group| group.delete(:active_at) }
  end

  def chat_index_group_key_sql
    {
      "date" => "DATE(#{chat_activity_order_sql})",
      "repository" => "COALESCE(CAST(chat_attachments.attachable_id AS CHAR), 'general')",
      "status" => "CASE WHEN chat_participants.hidden_at IS NOT NULL THEN 'hidden' WHEN #{chat_index_unread_sql} THEN 'unread' ELSE 'active' END",
      "mode" => "COALESCE(chat_sessions.mode, 'planning')",
      "chat_type" => chat_index_chat_type_sql,
      "agent" => chat_index_agent_sql
    }.fetch(chat_index_settings.fetch(:group_by))
  end

  def chat_index_group_match_sql(group_by)
    {
      "date" => "DATE(#{chat_activity_order_sql}) = ?",
      "repository" => "COALESCE(CAST(chat_attachments.attachable_id AS CHAR), 'general') = ?",
      "status" => "CASE WHEN chat_participants.hidden_at IS NOT NULL THEN 'hidden' WHEN #{chat_index_unread_sql} THEN 'unread' ELSE 'active' END = ?",
      "mode" => "COALESCE(chat_sessions.mode, 'planning') = ?",
      "chat_type" => "#{chat_index_chat_type_sql} = ?",
      "agent" => "#{chat_index_agent_sql} = ?"
    }.fetch(group_by)
  end

  def chat_index_agent_sql
    "COALESCE(NULLIF(chat_sessions.chat_provider, ''), 'claude')"
  end

  def chat_index_chat_type_sql
    "CASE WHEN COALESCE(chat_sessions.origin_platform, '') <> '' THEN 'external' WHEN chat_sessions.conversation_kind = 'group' THEN 'group' ELSE 'agent' END"
  end

  def chat_index_chat_type_for(chat_session)
    return "external" if chat_session.origin_platform.present?
    return "group" if chat_session.conversation_kind == "group"

    "agent"
  end

  def chat_index_external_chat_type_available?
    configured_platforms = PlatformIdentity.available_platforms.select do |platform|
      PlatformIdentity::PlatformConfig::Base.for(platform).configured?
    end
    return false if configured_platforms.empty?

    Current.user.platform_identities.where(platform: configured_platforms).exists?
  end

  def chat_index_order_sql
    "chat_sessions.pinned DESC, #{chat_index_sort_sql}, chat_sessions.id DESC"
  end

  def chat_index_empty_status_groups
    return %w[unread active hidden] if chat_index_settings.fetch(:status) == "all"

    [ "unread", chat_index_settings.fetch(:status) ].uniq
  end

  def chat_index_unread_sql
    "chat_sessions.last_message_at IS NOT NULL " \
      "AND (COALESCE(chat_participants.last_read_at, chat_sessions.last_read_at) IS NULL " \
      "OR chat_sessions.last_message_at > COALESCE(chat_participants.last_read_at, chat_sessions.last_read_at))"
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
