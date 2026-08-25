# Chat-search + filter helpers extracted from Api::V1::App::ChatsController.
#
# Backing the search / search_messages / filter endpoints: build the grouped
# cross-chat search payload and the single-scope payload, resolve the current
# user's searchable chat scope with the optional attachable filter, run the
# FTS/LIKE match rows, and serialize results/matches. They read the current
# user's chats, so they mix straight back in with no behavior change. Kept
# private on include.
module ChatSearch
  private

  SEARCH_PAGE_SIZE = 20
  SEARCH_TOP_MATCHES = 3

  def search_payload_for_query(scope, query, page)
    allowed_session_ids = scope.distinct.pluck(:id).map(&:to_i)
    grouped_matches = []
    matches_by_chat = {}

    chat_search_rows(query).each do |row|
      chat_session_id = row.fetch(:chat_session_id).to_i
      next unless allowed_session_ids.include?(chat_session_id)

      grouped_matches << chat_session_id unless matches_by_chat.key?(chat_session_id)
      matches_by_chat[chat_session_id] ||= []
      matches_by_chat[chat_session_id] << row
    end

    total = grouped_matches.length
    paged_chat_ids = grouped_matches.slice(search_offset(page), SEARCH_PAGE_SIZE) || []
    sessions_by_id = Current.user.accessible_chat_sessions
      .where(id: paged_chat_ids)
      .preload(repository_attachments: :attachable)
      .index_by(&:id)

    {
      results: paged_chat_ids.filter_map do |chat_session_id|
        chat_search_result_json(sessions_by_id[chat_session_id], matches_by_chat.fetch(chat_session_id))
      end,
      total: total,
      page: page,
      per_page: SEARCH_PAGE_SIZE
    }
  end

  def search_payload_for_scope(scope, page)
    total = scope.distinct.count
    sessions = scope
      .distinct
      .preload(repository_attachments: :attachable)
      .order(updated_at: :desc, id: :desc)
      .offset(search_offset(page))
      .limit(SEARCH_PAGE_SIZE)

    {
      results: sessions.map { |chat_session| chat_filter_result_json(chat_session) },
      total: total,
      page: page,
      per_page: SEARCH_PAGE_SIZE
    }
  end

  def filtered_chat_search_scope
    scope = Current.user.accessible_chat_sessions.visible.active
    scope = apply_chat_attachment_filter(scope, "Repository", :repository_id)
    return scope if performed?

    scope = apply_chat_attachment_filter(scope, "Epic", :epic_id)
    return scope if performed?

    apply_chat_attachment_filter(scope, "Job", :job_id)
  end

  def apply_chat_attachment_filter(scope, attachable_type, param_name)
    attachable_id = optional_positive_integer_param(param_name)
    return scope unless attachable_id

    alias_name = "chat_attachments_#{param_name}_filter"
    quoted_alias = ApplicationRecord.connection.quote_table_name(alias_name)
    quoted_type = ApplicationRecord.connection.quote(attachable_type)

    scope.joins(<<~SQL.squish)
      INNER JOIN chat_attachments #{quoted_alias}
        ON #{quoted_alias}.chat_session_id = chat_sessions.id
        AND #{quoted_alias}.attachable_type = #{quoted_type}
        AND #{quoted_alias}.attachable_id = #{attachable_id}
    SQL
  end

  def optional_positive_integer_param(name)
    raw = params[name]
    return if raw.blank?

    value = Integer(raw, exception: false)
    return value if value&.positive?

    render_error("bad_request", "#{name} must be a positive integer.", status: :bad_request)
    nil
  end

  def search_query
    params[:q].to_s.strip
  end

  def search_page
    [ Integer(params[:page], exception: false).to_i, 1 ].max
  end

  def search_offset(page)
    (page - 1) * SEARCH_PAGE_SIZE
  end

  def chat_search_rows(query, chat_session_id: nil)
    ChatMessageSearchIndex.search(
      query,
      user_id: Current.user.id,
      chat_session_id: chat_session_id,
      limit: nil,
      snippet_start: "<b>",
      snippet_end: "</b>",
      snippet_tokens: 50
    )
  end

  def chat_search_result_json(chat_session, rows)
    return unless chat_session

    top_matches = rows.first(SEARCH_TOP_MATCHES).map { |row| chat_search_match_json(row) }
    {
      chat_session_id: chat_session.id,
      chat_title: chat_search_title(chat_session),
      best_snippet: top_matches.first&.fetch(:snippet),
      best_match_message_id: top_matches.first&.fetch(:message_id),
      top_matches: top_matches,
      total_match_count: rows.length,
      has_more_matches: rows.length > SEARCH_TOP_MATCHES
    }
  end

  def chat_filter_result_json(chat_session)
    {
      chat_session_id: chat_session.id,
      chat_title: chat_search_title(chat_session),
      best_snippet: nil,
      best_match_message_id: nil,
      top_matches: [],
      total_match_count: 0,
      has_more_matches: false
    }
  end

  def chat_search_match_json(row)
    {
      message_id: row.fetch(:chat_message_id).to_i,
      role: row.fetch(:role),
      snippet: row.fetch(:snippet),
      created_at: row.fetch(:created_at)
    }
  end

  def chat_search_title(chat_session)
    chat_session.title.presence || ChatSession.fallback_title_for(chat_session.repository)
  end
end
