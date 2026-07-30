class TestCaseSearchIndex < SearchRecord
  include FtsQueryParser

  class << self
    def upsert(test_case)
      connection.transaction do
        connection.exec_delete(
          "DELETE FROM test_case_fts WHERE test_case_id = ?",
          "TestCaseSearchIndex Delete",
          [ bind(test_case.id) ]
        )

        connection.exec_insert(
          <<~SQL.squish,
            INSERT INTO test_case_fts (
              name,
              suite_name,
              file_path,
              test_case_id,
              user_id,
              repository_id,
              status,
              created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          "TestCaseSearchIndex Upsert",
          [
            bind(test_case.name.to_s),
            bind(test_case.suite_name.to_s),
            bind(test_case.file_path.to_s),
            bind(test_case.id),
            bind(test_case.repository.user_id),
            bind(test_case.repository_id),
            bind(test_case.status),
            bind(test_case.created_at&.iso8601)
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
            test_case_id,
            bm25(test_case_fts) AS rank,
            snippet(test_case_fts, -1, ?, ?, '...', ?) AS snippet
          FROM test_case_fts
          WHERE test_case_fts MATCH ? AND user_id = ?
          ORDER BY rank ASC, created_at DESC, test_case_id DESC
          #{limit_sql}
        SQL
        "TestCaseSearchIndex Search",
        binds
      )

      rows.map(&:symbolize_keys)
    end
  end
end
