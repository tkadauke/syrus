class TestIdentitySearchIndex < SearchRecord
  include FtsQueryParser

  class << self
    def upsert(test_identity)
      connection.transaction do
        delete(test_identity.id)
        insert(test_identity)
      end
    end

    def upsert_many(test_identities)
      test_identities = Array(test_identities)
      return if test_identities.empty?

      connection.transaction do
        delete_many(test_identities.map(&:id))
        test_identities.each { |test_identity| insert(test_identity) }
      end
    end

    def delete(test_identity_id)
      connection.exec_delete(
        "DELETE FROM test_identity_fts WHERE test_identity_id = ?",
        "TestIdentitySearchIndex Delete",
        [ bind(test_identity_id) ]
      )
    end

    def delete_many(test_identity_ids)
      ids = Array(test_identity_ids).filter_map { |id| Integer(id, exception: false) }.uniq
      return if ids.empty?

      ids.each_slice(500) do |slice|
        placeholders = ([ "?" ] * slice.size).join(", ")
        connection.exec_delete(
          "DELETE FROM test_identity_fts WHERE test_identity_id IN (#{placeholders})",
          "TestIdentitySearchIndex Delete Many",
          slice.map { |id| bind(id) }
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
            test_identity_id,
            bm25(test_identity_fts) AS rank,
            snippet(test_identity_fts, -1, ?, ?, '...', ?) AS snippet
          FROM test_identity_fts
          WHERE test_identity_fts MATCH ? AND user_id = ?
          ORDER BY rank ASC, last_seen_at DESC, test_identity_id DESC
          #{limit_sql}
        SQL
        "TestIdentitySearchIndex Search",
        binds
      )

      rows.map(&:symbolize_keys)
    end

    private

    def insert(test_identity)
      connection.exec_insert(
        <<~SQL.squish,
          INSERT INTO test_identity_fts (
            name,
            suite_name,
            file_path,
            test_identity_id,
            user_id,
            repository_id,
            last_status,
            last_seen_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        "TestIdentitySearchIndex Insert",
        [
          bind(test_identity.name.to_s),
          bind(test_identity.suite_name.to_s),
          bind(test_identity.file_path.to_s),
          bind(test_identity.id),
          bind(test_identity.repository.user_id),
          bind(test_identity.repository_id),
          bind(test_identity.last_status.to_s),
          bind(test_identity.last_seen_at&.iso8601)
        ]
      )
    end
  end
end
