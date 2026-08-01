# Chat index / recent-chats payload builders extracted from
# Api::V1::App::ChatsController.
#
# These assemble the sidebar's recent-chats list and the grouped chat index
# (General + one group per attached repository), including the keyset
# pagination cursor over the "pinned, then last-activity" ordering. They are
# pure controller helpers (reading `params` and `Current.user`, delegating to
# the controller's own `chat_json` / `chat_unread?` / `render_error`), so they
# mix straight back in with no behavior change. Kept private on include.
module ChatIndexPayload
  private

  CHAT_INDEX_GROUP_SIZE = 5

  def recent_chats_json(current_chat_session)
    chat_ids = PerformanceLogging.phase("chat_recent_chats.ids", chat_id: current_chat_session.id) do
      Current.user.chat_sessions
        .visible
        .ordinary_chats
        .order(Arel.sql("chat_sessions.pinned DESC, #{chat_activity_order_sql} DESC"), id: :desc)
        .limit(20)
        .pluck(:id)
    end

    chat_ids = chat_ids.first(19) + [ current_chat_session.id ] if current_chat_session.hidden_at.blank? && !chat_ids.include?(current_chat_session.id)

    PerformanceLogging.phase("chat_recent_chats.serialize", chat_id: current_chat_session.id, count: chat_ids.size) do
      Current.user.chat_sessions
        .visible
        .ordinary_chats
        .where(id: chat_ids)
        .preload(repository_attachments: :attachable)
        .to_a
        .sort_by { |chat_session| [ chat_activity_at(chat_session), chat_session.id ] }
        .reverse
        .map do |chat_session|
          chat_json(chat_session).merge(
            current: chat_session.id == current_chat_session.id,
            last_message_at: chat_session.last_message_at&.iso8601,
            unread: chat_unread?(chat_session),
            created_at: chat_session.created_at.iso8601,
            updated_at: chat_session.updated_at.iso8601
          )
        end
    end
  end

  def recent_chats_index_json
    PerformanceLogging.phase("chat_index.groups") do
      groups = []
      general_chats, general_has_more = PerformanceLogging.phase("chat_index.general_group") { paginated_chat_index_group(chat_index_group_scope(nil)) }
      if general_chats.any?
        groups << chat_index_group_json(
          key: "general",
          label: "General",
          repository_id: nil,
          chats: general_chats,
          has_more: general_has_more
        )
      end

      repositories = PerformanceLogging.phase("chat_index.repositories") { chat_index_repositories.to_a }
      repositories.each do |repository|
        chats, has_more = PerformanceLogging.phase("chat_index.repository_group", repository_id: repository.id) { paginated_chat_index_group(chat_index_group_scope(repository.id)) }
        next if chats.blank?

        groups << chat_index_group_json(
          key: "repository-#{repository.id}",
          label: repository.slug,
          repository_id: repository.id,
          chats: chats,
          has_more: has_more
        )
      end

      groups.sort_by { |group| group.delete(:active_at) || Time.at(0) }.reverse
    end
  end

  def supervisor_chat_index_json
    return unless Feature.admin_supervisor_chat_enabled?
    return unless Current.user.admin?

    chat_session = SupervisorChat.ensure_for!(Current.user)
    chat_index_json(chat_session).merge(supervisor_unread_summary(chat_session))
  end

  def chat_index_group_json(key:, label:, repository_id:, chats:, has_more:)
    {
      key: key,
      label: label,
      repository_id: repository_id,
      chats: chats.map { |chat_session| chat_index_json(chat_session) },
      has_more: has_more,
      active_at: chats.map { |chat_session| chat_activity_timestamp(chat_session) }.max
    }
  end

  def chat_index_json(chat_session)
    chat_json(chat_session).merge(
      last_message_at: chat_session.last_message_at&.iso8601,
      unread: chat_unread?(chat_session),
      created_at: chat_session.created_at.iso8601,
      updated_at: chat_session.updated_at.iso8601
    )
  end

  def paginated_chat_index_group(scope, before_chat: nil)
    PerformanceLogging.phase("chat_index.paginated_group", before_chat_id: before_chat&.id) do
      scope = chat_index_before(scope, before_chat) if before_chat
      fetched = scope.preload(repository_attachments: :attachable).limit(CHAT_INDEX_GROUP_SIZE + 1).to_a
      [ fetched.first(CHAT_INDEX_GROUP_SIZE), fetched.size > CHAT_INDEX_GROUP_SIZE ]
    end
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
    scope = Current.user.chat_sessions
      .visible
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
    repository_ids = Current.user.chat_sessions
      .visible
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
    unread_messages = chat_session.messages.where(role: "system")
    unread_messages = unread_messages.where("created_at > ?", chat_session.last_read_at) if chat_session.last_read_at.present?

    severity_rank = { "info" => 0, "warning" => 1, "critical" => 2 }
    severities = unread_messages.limit(200).filter_map do |message|
      content = message.content
      next unless content.is_a?(Hash)

      severity = content.dig("supervisor_event", "severity").to_s
      severity if severity_rank.key?(severity)
    end

    unread_count = unread_messages.count
    {
      unread: unread_count.positive? || (chat_unread?(chat_session) && chat_session.messages.exists?),
      supervisor_unread_count: unread_count,
      supervisor_unread_severity: severities.max_by { |severity| severity_rank.fetch(severity) }
    }
  end
end
