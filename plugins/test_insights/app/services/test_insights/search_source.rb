module TestInsights
  # Owns the test_identity_fts index and the "test_case" global-search type.
  class SearchSource
    TABLE_SQL = <<~SQL.freeze
      CREATE VIRTUAL TABLE IF NOT EXISTS test_identity_fts
      USING fts5(
        name,
        suite_name,
        file_path,
        test_identity_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        last_status UNINDEXED,
        last_seen_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL

    def self.search_tables = { "test_identity_fts" => TABLE_SQL }

    def self.search_type = "test_case"
    def self.filter_subject = :test_case
    def self.row_id_key = :test_identity_id

    def self.search_rows(query:, user:, limit:)
      SearchIndex.search(query, user_id: user.id, limit: limit)
    end

    def self.filtered_scope(ids:, tree:, user:)
      ::Filters::Compiler.call(
        ::Filters::Ast.parse(tree),
        scope: TestIdentity.joins(:repository).where(repositories: { user_id: user.id }, id: ids),
        user: user,
        subject: :test_case
      )
    end

    def self.result_json(row:, user:)
      identity = TestIdentity.includes(:repository).find_by(id: row.fetch(:test_identity_id).to_i)
      return nil if identity.nil?

      {
        type: "test_case",
        id: identity.id,
        title: identity.name,
        suite_name: identity.suite_name,
        file_path: identity.file_path,
        snippet: row[:snippet],
        rank: row[:rank],
        # The Tests view is now this plugin's repo-page tab, not a core
        # ?tab=tests query param.
        path: "/repositories/#{identity.repository_id}/plugin/tests?test_id=#{identity.id}",
        state: identity.last_status,
        repository_slug: identity.repository.slug,
        created_at: identity.last_seen_at&.iso8601
      }
    end
  end
end
