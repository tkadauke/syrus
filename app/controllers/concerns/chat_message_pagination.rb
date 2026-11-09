# Chat-message pagination + serialization helpers extracted from
# Api::V1::App::ChatsController.
#
# These build the keyset-paginated message window (latest page, or the page
# before a cursor id) and serialize messages through the shared payload
# builder. `ChatMessageWindow` decides how far a window reaches -- it is sized
# by rendered rows rather than message count, so see it before assuming a
# window holds a fixed number of messages. On MySQL they force the
# (session_id, id) cursor index so keyset
# pagination stays on the intended plan. Active payload reads force the
# (session_id, deleted_at, id) index so soft-deleted rows don't pollute large
# chat scans. They read only the chat session's messages, so they mix straight
# back in with no behavior change. Kept private on include.
module ChatMessagePagination
  private

  def paginated_tail(chat_session)
    ChatMessageWindow.new(message_scope(chat_session)).call
  end

  def paginated_before(chat_session, before_id, limit: nil)
    options = {}
    options[:max_messages] = [ limit.to_i, 1 ].max if limit
    ChatMessageWindow.new(message_scope(chat_session), **options).call(before: before_id&.positive? ? before_id : nil)
  end

  def message_scope(chat_session)
    scope = ChatMessage.active.where(chat_session_id: chat_session.id)
    scope = force_chat_message_cursor_index(scope) if mysql_adapter?

    scope.includes(:pending_action)
  end

  def force_chat_message_cursor_index(scope)
    scope.from(Arel.sql("#{ChatMessage.quoted_table_name} FORCE INDEX (idx_chat_messages_active_tail)"))
  end

  def mysql_adapter?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")
  end

  def messages_json(messages, repository:)
    ::App::ChatMessagePayload.messages(messages, repository: repository)
  end
end
