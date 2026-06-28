class ChatMessageSearchIndex < SearchRecord
  include FtsQueryParser

  INDEXED_MESSAGE_KEY_PREFIX = "indexed_chat_message:".freeze

  class << self
    def insert(message)
      return unless indexable?(message)
      return if indexed?(message.id)

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
            bind(content_for(message)),
            bind(message.chat_session.user_id),
            bind(message.chat_session_id),
            bind(message.id),
            bind(message.role),
            bind(message.created_at&.iso8601)
          ]
        )
        mark_indexed!(message.id)
      end
    end

    def search(query, user_id:, chat_session_id: nil, limit: 20, snippet_start: "<mark>", snippet_end: "</mark>", snippet_tokens: 24)
      predicates = [ "chat_message_fts MATCH ?", "user_id = ?" ]
      binds = [
        bind(snippet_start.to_s),
        bind(snippet_end.to_s),
        bind(snippet_tokens.to_i),
        bind(parse_fts_query(query)),
        bind(user_id)
      ]

      if chat_session_id.present?
        predicates << "chat_session_id = ?"
        binds << bind(chat_session_id)
      end

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

    def indexed?(message_id)
      connection.select_value(
        "SELECT 1 FROM chat_search_metadata WHERE key = ? LIMIT 1",
        "ChatMessageSearchIndex Indexed",
        [ bind(indexed_message_key(message_id)) ]
      ).present?
    end

    def indexable?(message)
      message.role.in?(%w[user assistant]) && message.content.present? && content_for(message).present?
    end

    private

    def bind(value)
      ActiveRecord::Relation::QueryAttribute.new(nil, value, ActiveRecord::Type::Value.new)
    end

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
  end
end
