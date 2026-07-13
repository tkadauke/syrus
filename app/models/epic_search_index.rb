class EpicSearchIndex < SearchRecord
  include FtsQueryParser

  class << self
    def upsert(epic)
      connection.transaction do
        connection.exec_delete(
          "DELETE FROM epic_fts WHERE epic_id = ?",
          "EpicSearchIndex Delete",
          [ bind(epic.id) ]
        )

        connection.exec_insert(
          <<~SQL.squish,
            INSERT INTO epic_fts (
              title,
              description,
              epic_id,
              user_id,
              repository_id,
              state,
              created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
          "EpicSearchIndex Upsert",
          [
            bind(epic.title.to_s),
            bind(epic.description.to_s),
            bind(epic.id),
            bind(epic.user_id),
            bind(epic.repository_id),
            bind(epic.state),
            bind(epic.created_at&.iso8601)
          ]
        )
      end
    end

    def search(query, user_id:, limit: 20, snippet_start: "<mark>", snippet_end: "</mark>", snippet_tokens: 16)
      binds = [
        bind(snippet_start.to_s),
        bind(snippet_end.to_s),
        bind(snippet_tokens.to_i),
        bind(parse_fts_query(query)),
        bind(user_id)
      ]

      limit_sql = ""
      if limit.present?
        limit_sql = "LIMIT ?"
        binds << bind(limit.to_i)
      end

      rows = connection.exec_query(
        <<~SQL.squish,
          SELECT
            epic_id,
            bm25(epic_fts) AS rank,
            snippet(epic_fts, -1, ?, ?, '...', ?) AS snippet
          FROM epic_fts
          WHERE epic_fts MATCH ? AND user_id = ?
          ORDER BY rank ASC, created_at DESC, epic_id DESC
          #{limit_sql}
        SQL
        "EpicSearchIndex Search",
        binds
      )

      rows.map(&:symbolize_keys)
    end
  end
end
