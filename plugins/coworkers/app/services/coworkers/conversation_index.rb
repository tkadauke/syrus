require "base64"

class Coworkers::ConversationIndex
  PAGE_SIZE = 20
  SEARCH_SCAN_LIMIT = 1_000
  SNIPPET_TOKENS = 32
  SORTS = %w[last_activity title created_at].freeze

  class InvalidCursor < StandardError; end

  def initialize(coworker:, user:, filter: nil, sort: nil, cursor: nil)
    @coworker = coworker
    @user = user
    @filter = Syrus::Host::Filters::QueryParam.decode(filter)
    @sort = SORTS.include?(sort) ? sort : "last_activity"
    @cursor = cursor
  end

  def call
    main_link = coworker.coworker_chats.where(role: "main").includes(chat_session: :chat_participants).first
    relation, search_query, title_match_ids, result_count_exact = filtered_relation
    total = relation.count
    records = page(relation).includes(:chat_participants).to_a
    search_rows = search_rows_for(search_query, records)
    messages = last_messages(records)
    pending_ids = Syrus::Host::ChatPendingActionRecord.where(chat_session_id: records.map(&:id), state: %w[queued pending confirming])
      .distinct.pluck(:chat_session_id).to_set

    {
      main_chat: main_link && summary(main_link.chat_session, main: true, title_match_ids: title_match_ids),
      side_chats: records.map do |chat|
        summary(chat, message: messages[chat.id], search_rows: search_rows[chat.id], title_match_ids: title_match_ids,
          active_work: chat.turn_in_flight? || pending_ids.include?(chat.id))
      end,
      result_count: total,
      result_count_exact: result_count_exact,
      next_cursor: records.length == PAGE_SIZE ? encode_cursor(records.last) : nil,
      filter: filter || { "and" => [] },
      filter_schema: filter_schema,
      sort: sort
    }
  end

  private

  attr_reader :coworker, :user, :filter, :sort, :cursor

  def base_relation
    ids = coworker.coworker_chats.where(role: "side").select(:chat_session_id)
    Syrus::Host::ChatSessionRecord.where(id: ids, user_id: user.id, deleted_at: nil)
  end

  def filtered_relation
    relation = base_relation
    search_query = nil
    title_match_ids = Set.new
    result_count_exact = true
    chips.each do |chip|
      field = chip.fetch("field")
      value = chip["value"]
      case field
      when "search"
        query = value.to_s.strip
        next if query.blank?
        candidate_ids = ordered(relation).limit(SEARCH_SCAN_LIMIT + 1).pluck(:id)
        result_count_exact &&= candidate_ids.length <= SEARCH_SCAN_LIMIT
        candidate_ids = candidate_ids.first(SEARCH_SCAN_LIMIT)
        message_ids = Syrus::Host::ChatMessageSearchIndex.matching_chat_session_page(
          query, chat_session_ids: candidate_ids, limit: SEARCH_SCAN_LIMIT, offset: 0
        ).fetch(:chat_session_ids)
        title_ids = relation.where(id: candidate_ids)
          .where("LOWER(chat_sessions.title) LIKE ?", "%#{Syrus::Host::Record.sanitize_sql_like(query.downcase)}%")
          .limit(SEARCH_SCAN_LIMIT).pluck(:id)
        title_match_ids = title_ids.to_set
        relation = relation.where(id: message_ids | title_ids)
        search_query = query
      when "status"
        relation = relation.joins(:chat_participants).where(chat_participants: { user_id: user.id })
        relation = value == "archived" ? relation.where.not(chat_participants: { hidden_at: nil }) : relation.where(chat_participants: { hidden_at: nil })
      when "unread"
        relation = relation.joins(:chat_participants)
          .where(chat_participants: { user_id: user.id })
          .where("chat_participants.last_read_at IS NULL OR chat_sessions.last_message_at > chat_participants.last_read_at")
      when "created_at", "last_activity_at"
        relation = apply_date(relation, field == "created_at" ? "chat_sessions.created_at" : activity_sql, chip)
      when "active_work"
        pending = Syrus::Host::ChatPendingActionRecord.where(state: %w[queued pending confirming]).select(:chat_session_id)
        relation = relation.where("chat_sessions.turn_in_flight = ? OR chat_sessions.id IN (?)", true, pending)
      end
    end
    [ relation.distinct, search_query, title_match_ids, result_count_exact ]
  end

  def chips
    return [] unless filter.is_a?(Hash)
    Array(filter["and"]).select { |node| node.is_a?(Hash) && node["field"].present? }
  end

  def apply_date(relation, column, chip)
    value = chip["value"]
    case chip["op"]
    when "before" then relation.where("#{column} < ?", Time.zone.parse(value.to_s))
    when "after" then relation.where("#{column} > ?", Time.zone.parse(value.to_s))
    when "between"
      from, to = Array(value)
      relation.where("#{column} BETWEEN ? AND ?", Time.zone.parse(from.to_s), Time.zone.parse(to.to_s))
    else relation
    end
  rescue ArgumentError
    relation.none
  end

  def page(relation)
    value, id = decode_cursor if cursor.present?
    case sort
    when "title"
      relation = relation.where("LOWER(COALESCE(chat_sessions.title, '')) > ? OR (LOWER(COALESCE(chat_sessions.title, '')) = ? AND chat_sessions.id > ?", value, value, id) if value
      ordered(relation).limit(PAGE_SIZE)
    when "created_at"
      relation = descending_page(relation, "chat_sessions.created_at", value, id) if value
      ordered(relation).limit(PAGE_SIZE)
    else
      relation = descending_page(relation, activity_sql, value, id) if value
      ordered(relation).limit(PAGE_SIZE)
    end
  end

  def ordered(relation)
    case sort
    when "title" then relation.order(Arel.sql("LOWER(COALESCE(chat_sessions.title, '')) ASC"), id: :asc)
    when "created_at" then relation.order(created_at: :desc, id: :desc)
    else relation.order(Arel.sql("#{activity_sql} DESC"), id: :desc)
    end
  end

  def descending_page(relation, column, value, id)
    relation.where("#{column} < ? OR (#{column} = ? AND chat_sessions.id < ?)", value, value, id)
  end

  def activity_sql = "COALESCE(chat_sessions.last_message_at, chat_sessions.created_at)"

  def encode_cursor(chat)
    value = sort == "title" ? chat.title.to_s.downcase : (sort == "created_at" ? chat.created_at : (chat.last_message_at || chat.created_at)).iso8601(6)
    Base64.urlsafe_encode64(JSON.generate([ value, chat.id ]), padding: false)
  end

  def decode_cursor
    decoded = JSON.parse(Base64.urlsafe_decode64(cursor.to_s))
    raise InvalidCursor, "invalid conversation cursor" unless decoded.is_a?(Array) && decoded.length == 2

    value, raw_id = decoded
    id = Integer(raw_id, exception: false)
    raise InvalidCursor, "invalid conversation cursor" unless value.is_a?(String) && id&.positive?

    value = Time.zone.iso8601(value) unless sort == "title"
    [ value, id ]
  rescue ArgumentError, JSON::ParserError, TypeError
    raise InvalidCursor, "invalid conversation cursor"
  end

  def last_messages(records)
    ids = records.map(&:id)
    return {} if ids.empty?
    latest_ids = Syrus::Host::ChatMessageRecord.active.where(chat_session_id: ids).group(:chat_session_id).maximum(:id).values
    Syrus::Host::ChatMessageRecord.where(id: latest_ids).index_by(&:chat_session_id)
  end

  def search_rows_for(query, records)
    return {} if query.blank? || records.empty?

    Syrus::Host::ChatMessageSearchIndex.top_matches_by_chat_session(
      query, chat_session_ids: records.map(&:id), matches_per_session: 1,
      snippet_start: "<mark>", snippet_end: "</mark>", snippet_tokens: SNIPPET_TOKENS
    ).group_by { |row| row.fetch(:chat_session_id).to_i }
  end

  def summary(chat, main: false, message: nil, search_rows: nil, title_match_ids: Set.new, active_work: false)
    participant = chat.chat_participants.find { |entry| entry.user_id == user.id }
    first_match = search_rows&.first
    {
      id: chat.id, title: chat.title.presence || Syrus::Host::ChatSessionRecord.fallback_title_for(chat.repository), path: "/chats/#{chat.id}",
      main: main, preview: message&.preview_text&.truncate(240), last_activity_at: (chat.last_message_at || chat.created_at).iso8601,
      created_at: chat.created_at.iso8601, archived: participant&.hidden_at.present?,
      unread: chat.last_message_at.present? && (participant&.last_read_at.blank? || chat.last_message_at > participant.last_read_at),
      active_work: active_work, title_match: title_match_ids.include?(chat.id),
      match_count: search_rows&.first&.fetch(:match_count, 0).to_i + (title_match_ids.include?(chat.id) ? 1 : 0),
      match: first_match && { message_id: first_match.fetch(:chat_message_id).to_i, snippet: first_match.fetch(:snippet) }
    }
  end

  def filter_schema
    [
      { field: "search", label: "Search", bucket: "text", operators: [ "contains" ], values: [], free_text_search: true },
      { field: "status", label: "Status", bucket: "select", operators: [ "is" ], values: [ { value: "active", label: "Active" }, { value: "archived", label: "Archived" } ] },
      { field: "unread", label: "Unread only", bucket: "boolean", operators: [ "is_true" ], values: [] },
      { field: "active_work", label: "Has active work", bucket: "boolean", operators: [ "is_true" ], values: [] },
      { field: "created_at", label: "Created", bucket: "date", operators: %w[before after between], values: [], date_precision: "date" },
      { field: "last_activity_at", label: "Last activity", bucket: "date", operators: %w[before after between], values: [], date_precision: "date" }
    ]
  end
end
