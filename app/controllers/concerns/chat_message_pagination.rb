# Chat-message pagination + serialization helpers extracted from
# Api::V1::App::ChatsController.
#
# These build the keyset-paginated message window (latest page, or the page
# before a cursor id) and serialize messages through the shared payload
# builder. On MySQL they force the (session_id, id) cursor index so keyset
# pagination stays on the intended plan. Active payload reads force the
# (session_id, deleted_at, id) index so soft-deleted rows don't pollute large
# chat scans. They read only the chat session's messages, so they mix straight
# back in with no behavior change. Kept private on include.
module ChatMessagePagination
  private

  PAGE_SIZE = ChatSession::MESSAGE_PAGE_SIZE

  def paginated_tail(chat_session)
    scope = message_scope(chat_session)
    fetched = scope.order(id: :desc).limit(PAGE_SIZE + 1).to_a
    has_more = fetched.size > PAGE_SIZE
    [ fetched.first(PAGE_SIZE).reverse, has_more ]
  end

  def paginated_before(chat_session, before_id)
    scope = message_scope(chat_session)
    scope = scope.where("id < ?", before_id) if before_id&.positive?
    fetched = scope.order(id: :desc).limit(PAGE_SIZE + 1).to_a
    has_more = fetched.size > PAGE_SIZE
    [ fetched.first(PAGE_SIZE).reverse, has_more ]
  end

  def message_scope(chat_session)
    scope = ChatMessage.active.where(chat_session_id: chat_session.id)
    scope = force_chat_message_cursor_index(scope) if mysql_adapter?

    scope.includes(:pending_action, proposal: [ :repository, :job, :epic, :target_epic, dependencies: [], child_proposals: [ :repository, :job, dependencies: [] ] ])
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
