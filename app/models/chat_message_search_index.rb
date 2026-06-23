class ChatMessageSearchIndex < SearchRecord
  class << self
    def insert(message)
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
    end

    def search(query, user_id:, limit: 20)
      rows = connection.exec_query(
        <<~SQL.squish,
          SELECT
            chat_message_id,
            chat_session_id,
            user_id,
            role,
            created_at,
            snippet(chat_message_fts, 0, '<mark>', '</mark>', '...', 24) AS snippet,
            bm25(chat_message_fts) AS rank
          FROM chat_message_fts
          WHERE chat_message_fts MATCH ? AND user_id = ?
          ORDER BY rank ASC, created_at DESC, chat_message_id DESC
          LIMIT ?
        SQL
        "ChatMessageSearchIndex Search",
        [
          bind(query.to_s),
          bind(user_id),
          bind(limit.to_i)
        ]
      )

      rows.map(&:symbolize_keys)
    end

    private

    def bind(value)
      ActiveRecord::Relation::QueryAttribute.new(nil, value, ActiveRecord::Type::Value.new)
    end

    def content_for(message)
      content = message.content
      return content if content.is_a?(String)
      return content["text"].to_s if content.is_a?(Hash) && content.key?("text")

      JSON.generate(content)
    end
  end
end
