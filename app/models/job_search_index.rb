class JobSearchIndex < SearchRecord
  include FtsQueryParser

  class << self
    def upsert(job)
      connection.transaction do
        connection.exec_delete(
          "DELETE FROM job_fts WHERE job_id = ?",
          "JobSearchIndex Delete",
          [ bind(job.id) ]
        )

        connection.exec_insert(
          <<~SQL.squish,
            INSERT INTO job_fts (
              title,
              body,
              job_id,
              user_id,
              repository_id,
              state,
              created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
          "JobSearchIndex Upsert",
          [
            bind(job.issue_title.to_s),
            bind(body_for(job)),
            bind(job.id),
            bind(job.user_id),
            bind(job.repository_id),
            bind(job.state),
            bind(job.created_at&.iso8601)
          ]
        )
      end
    end

    def search(query, user_id:, limit: 20, snippet_start: "<mark>", snippet_end: "</mark>", snippet_tokens: 24)
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
            job_id,
            bm25(job_fts) AS rank,
            snippet(job_fts, -1, ?, ?, '...', ?) AS snippet
          FROM job_fts
          WHERE job_fts MATCH ? AND user_id = ?
          ORDER BY rank ASC, created_at DESC, job_id DESC
          #{limit_sql}
        SQL
        "JobSearchIndex Search",
        binds
      )

      rows.map(&:symbolize_keys)
    end

    private

    def body_for(job)
      [ job.issue_body, (job.description if job.respond_to?(:description)) ].compact_blank.join("\n\n")
    end
  end
end
