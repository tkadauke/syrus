module GlobalSearch
  class JobIndex < ::SearchRecord
    include FtsQueryParser

    class << self
      def upsert(job)
        connection.transaction do
          connection.exec_delete(
            "DELETE FROM job_fts WHERE job_id = ?",
            "GlobalSearch::JobIndex Delete",
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
            "GlobalSearch::JobIndex Upsert",
            [
              bind(index_text(job.issue_title, job, :title)),
              bind(index_text(body_for(job), job, :body)),
              bind(job.id),
              bind(job.user_id),
              bind(job.repository_id),
              bind(job.state),
              bind(job.created_at&.iso8601)
            ]
          )
        end
      end

      def search(query, limit: 20, offset: 0, snippet_start: "<mark>", snippet_end: "</mark>", snippet_tokens: 24)
        binds = [
          bind(snippet_start.to_s),
          bind(snippet_end.to_s),
          bind(snippet_tokens.to_i),
          bind(parse_fts_query(query))
        ]

        limit_sql = ""
        if limit.present?
          limit_sql = "LIMIT ? OFFSET ?"
          binds << bind(limit.to_i)
          binds << bind(offset.to_i)
        end

        rows = connection.exec_query(
          <<~SQL.squish,
            SELECT
              job_id,
              bm25(job_fts) AS rank,
              snippet(job_fts, -1, ?, ?, '...', ?) AS snippet
            FROM job_fts
            WHERE job_fts MATCH ?
            ORDER BY rank ASC, created_at DESC, job_id DESC
            #{limit_sql}
          SQL
          "GlobalSearch::JobIndex Search",
          binds
        )

        rows.map(&:symbolize_keys)
      end

      private

      def index_text(value, job, field)
        SearchIndexWriteLimits.prefix(value, index: "job", record_id: job.id, field: field)
      end

      def body_for(job)
        [
          job.issue_body,
          canonical_summary_for(job),
          (job.description if job.respond_to?(:description))
        ].compact_blank.join("\n\n")
      end

      def canonical_summary_for(job)
        job.workflows
           .where(state: "succeeded")
           .order(Arel.sql("COALESCE(finished_at, created_at) DESC"), id: :desc)
           .lazy
           .filter_map { |workflow| workflow.artifact("job_metadata") }
           .find { |metadata| metadata.is_a?(Hash) && metadata["changed"] == true && metadata["summary"].present? }
           &.fetch("summary")
      end
    end
  end
end
