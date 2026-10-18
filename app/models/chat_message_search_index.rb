class ChatMessageSearchIndex < SearchRecord
  include FtsQueryParser

  INDEXED_MESSAGE_KEY_PREFIX = "indexed_chat_message:".freeze

  class << self
    def insert(message)
      return unless indexable?(message)
      return if indexed?(message.id)

      # A chat deleted (or soft-deleted) mid-flight must not repopulate the
      # index after ChatSessionCleanupJob purged its rows: re-fetch the
      # ChatSession from the primary DB (never a possibly-stale cached
      # association) right before inserting, and skip when it is gone or
      # soft-deleted.
      chat_session = ChatSession.active.find_by(id: message.chat_session_id)
      return unless chat_session

      connection.transaction do
        connection.exec_insert(
          <<~SQL.squish,
            INSERT INTO chat_message_fts (
              content,
              user_id,
              chat_session_id,
              chat_message_id,
              role,
              created_at
            )
            VALUES (?, ?, ?, ?, ?, ?)
          SQL
          "ChatMessageSearchIndex Insert",
          [
            bind(indexed_content(message)),
            bind(chat_session.user_id),
            bind(message.chat_session_id),
            bind(message.id),
            bind(message.role),
            bind(message.created_at&.iso8601)
          ]
        )
        mark_indexed!(message.id)
      end
    end

    def search(
      query,
      chat_session_id: nil,
      chat_session_ids: nil,
      limit: 20,
      snippet_start: "<mark>",
      snippet_end: "</mark>",
      snippet_tokens: 24
    )
      scoped_chat_session_ids = Array(chat_session_ids)
      scoped_chat_session_ids << chat_session_id if chat_session_id.present?
      scoped_chat_session_ids = scoped_chat_session_ids.compact_blank.uniq
      return [] if scoped_chat_session_ids.empty?

      predicates = [ "chat_message_fts MATCH ?" ]
      binds = [
        bind(snippet_start.to_s),
        bind(snippet_end.to_s),
        bind(snippet_tokens.to_i),
        bind(parse_fts_query(query))
      ]

      predicates << "chat_session_id IN (#{([ '?' ] * scoped_chat_session_ids.size).join(', ')})"
      binds.concat(scoped_chat_session_ids.map { |id| bind(id) })

      limit_sql = ""
      if limit.present?
        limit_sql = "LIMIT ?"
        binds << bind(limit.to_i)
      end

      rows = connection.exec_query(
        <<~SQL.squish,
          SELECT
            chat_message_id,
            chat_session_id,
            user_id,
            role,
            created_at,
            snippet(chat_message_fts, 0, ?, ?, '...', ?) AS snippet,
            bm25(chat_message_fts) AS rank
          FROM chat_message_fts
          WHERE #{predicates.join(" AND ")}
          ORDER BY rank ASC, created_at DESC, chat_message_id DESC
          #{limit_sql}
        SQL
        "ChatMessageSearchIndex Search",
        binds
      )

      rows.map(&:symbolize_keys)
    end

    def matching_chat_session_page(query, chat_session_ids:, limit:, offset:)
      scoped_chat_session_ids = Array(chat_session_ids).compact_blank.uniq
      return { chat_session_ids: [], total: 0 } if scoped_chat_session_ids.empty?

      session_predicate = "chat_session_id IN (#{([ '?' ] * scoped_chat_session_ids.size).join(', ')})"
      query_bind = bind(parse_fts_query(query))
      session_binds = scoped_chat_session_ids.map { |id| bind(id) }
      total = connection.select_value(
        <<~SQL.squish,
          SELECT COUNT(DISTINCT chat_session_id)
          FROM chat_message_fts
          WHERE chat_message_fts MATCH ? AND #{session_predicate}
        SQL
        "ChatMessageSearchIndex Matching Session Count",
        [ query_bind, *session_binds ]
      ).to_i

      rows = connection.exec_query(
        <<~SQL.squish,
          WITH matches AS (
            SELECT
              chat_session_id,
              chat_message_id,
              created_at,
              bm25(chat_message_fts) AS rank
            FROM chat_message_fts
            WHERE chat_message_fts MATCH ? AND #{session_predicate}
          ), ranked_matches AS (
            SELECT
              *,
              ROW_NUMBER() OVER (
                PARTITION BY chat_session_id
                ORDER BY rank ASC, created_at DESC, chat_message_id DESC
              ) AS match_number
            FROM matches
          )
          SELECT chat_session_id
          FROM ranked_matches
          WHERE match_number = 1
          ORDER BY rank ASC, created_at DESC, chat_message_id DESC
          LIMIT ? OFFSET ?
        SQL
        "ChatMessageSearchIndex Matching Session Page",
        [ query_bind, *session_binds, bind(limit.to_i), bind(offset.to_i) ]
      )

      { chat_session_ids: rows.map { |row| row.fetch("chat_session_id").to_i }, total: total }
    end

    def top_matches_by_chat_session(
      query,
      chat_session_ids:,
      matches_per_session:,
      snippet_start: "<mark>",
      snippet_end: "</mark>",
      snippet_tokens: 24
    )
      scoped_chat_session_ids = Array(chat_session_ids).compact_blank.uniq
      return [] if scoped_chat_session_ids.empty?

      session_predicate = "chat_session_id IN (#{([ '?' ] * scoped_chat_session_ids.size).join(', ')})"
      rows = connection.exec_query(
        <<~SQL.squish,
          WITH matches AS (
            SELECT
              chat_message_id,
              chat_session_id,
              user_id,
              role,
              created_at,
              snippet(chat_message_fts, 0, ?, ?, '...', ?) AS snippet,
              bm25(chat_message_fts) AS rank
            FROM chat_message_fts
            WHERE chat_message_fts MATCH ? AND #{session_predicate}
          ), ranked_matches AS (
            SELECT
              *,
              ROW_NUMBER() OVER (
                PARTITION BY chat_session_id
                ORDER BY rank ASC, created_at DESC, chat_message_id DESC
              ) AS match_number,
              COUNT(*) OVER (PARTITION BY chat_session_id) AS match_count
            FROM matches
          )
          SELECT *
          FROM ranked_matches
          WHERE match_number <= ?
          ORDER BY rank ASC, created_at DESC, chat_message_id DESC
        SQL
        "ChatMessageSearchIndex Top Matches By Session",
        [
          bind(snippet_start.to_s),
          bind(snippet_end.to_s),
          bind(snippet_tokens.to_i),
          bind(parse_fts_query(query)),
          *scoped_chat_session_ids.map { |id| bind(id) },
          bind(matches_per_session.to_i)
        ]
      )

      rows.map(&:symbolize_keys)
    end

    def indexed?(message_id)
      connection.select_value(
        "SELECT 1 FROM chat_search_metadata WHERE key = ? LIMIT 1",
        "ChatMessageSearchIndex Indexed",
        [ bind(indexed_message_key(message_id)) ]
      ).present?
    end

    # Hard-deletes every FTS row (and its indexed-marker metadata) for a
    # chat session. Used when a ChatSession is destroyed so the search
    # index does not accumulate orphaned rows. No-ops when the search
    # schema has not been created (fresh installs, minimal test setups);
    # note `table_exists?` cannot detect FTS5 virtual tables, so the
    # missing-table case is handled by rescue instead.
    def delete_for_chat_session(chat_session_id)
      connection.transaction do
        message_ids = connection.select_values(
          "SELECT chat_message_id FROM chat_message_fts WHERE chat_session_id = ?",
          "ChatMessageSearchIndex Session Message Ids",
          [ bind(chat_session_id) ]
        )

        connection.exec_delete(
          "DELETE FROM chat_message_fts WHERE chat_session_id = ?",
          "ChatMessageSearchIndex Delete Session Rows",
          [ bind(chat_session_id) ]
        )

        message_ids.each do |message_id|
          connection.exec_delete(
            "DELETE FROM chat_search_metadata WHERE key = ?",
            "ChatMessageSearchIndex Delete Indexed Marker",
            [ bind(indexed_message_key(message_id)) ]
          )
        end
      end
    rescue ActiveRecord::StatementInvalid => e
      raise unless e.message.match?(/no such table/i)
    end

    def indexable?(message)
      message.role.in?(%w[user assistant]) && message.content.present? && content_for(message).present?
    end

    private

    def mark_indexed!(message_id)
      connection.exec_insert(
        "INSERT OR REPLACE INTO chat_search_metadata (key, value) VALUES (?, ?)",
        "ChatMessageSearchIndex Mark Indexed",
        [
          bind(indexed_message_key(message_id)),
          bind(Time.current.iso8601)
        ]
      )
    end

    def indexed_message_key(message_id)
      "#{INDEXED_MESSAGE_KEY_PREFIX}#{message_id}"
    end

    def content_for(message)
      content = message.content
      return content if content.is_a?(String)
      return content["text"].to_s if content.is_a?(Hash) && content.key?("text")

      JSON.generate(content)
    end

    def indexed_content(message)
      SearchIndexWriteLimits.prefix(content_for(message), index: "chat_message", record_id: message.id, field: :content)
    end
  end
end
