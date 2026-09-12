module DesignDocs
  class SearchIndex < SearchRecord
    self.table_name = "design_doc_fts"

    include FtsQueryParser

    class << self
      def upsert(design_doc)
        return unless table_available?

        connection.transaction do
          delete(design_doc.id)
          insert(design_doc)
        end
      end

      def rebuild!
        return unless table_available?

        connection.transaction do
          connection.execute("DELETE FROM design_doc_fts")
          DesignDocs::DesignDoc
            .includes(:owner_user, :repositories, :collaborator_users)
            .find_each { |design_doc| insert(design_doc) }
        end
      end

      def delete(design_doc_id)
        return unless table_available?

        connection.exec_delete(
          "DELETE FROM design_doc_fts WHERE design_doc_id = ?",
          "DesignDocs::SearchIndex Delete",
          [ bind(design_doc_id) ]
        )
      end

      def search(query, user:, limit: 20, snippet_start: "<mark>", snippet_end: "</mark>", snippet_tokens: 18)
        return [] unless table_available?

        limit_count = limit.present? ? limit.to_i : 20
        exact_rows = exact_doc_rows(query, user: user, snippet_start: snippet_start, snippet_end: snippet_end)
        rows = merge_exact_doc_rows(
          visible_search_fts_rows(
            query,
            limit: limit_count,
            user: user,
            excluded_ids: exact_rows.map { |row| row.fetch(:design_doc_id).to_i }.to_set,
            snippet_start: snippet_start,
            snippet_end: snippet_end,
            snippet_tokens: snippet_tokens
          ),
          exact_rows
        )

        rows.first(limit_count)
      end

      private

      def table_available?
        connection.select_value("SELECT name FROM sqlite_master WHERE name = 'design_doc_fts'").present?
      end

      def visible_search_fts_rows(query, limit:, user:, excluded_ids:, snippet_start:, snippet_end:, snippet_tokens:)
        rows = []
        batch_size = [ limit.to_i * 5, 100 ].max
        offset = 0

        loop do
          batch = search_fts_rows(
            query,
            limit: batch_size,
            offset: offset,
            snippet_start: snippet_start,
            snippet_end: snippet_end,
            snippet_tokens: snippet_tokens
          )
          break if batch.empty?

          visible_ids = visible_doc_ids(batch, user)
          batch.each do |row|
            design_doc_id = row.fetch(:design_doc_id).to_i
            next if excluded_ids.include?(design_doc_id)
            next unless visible_ids.include?(design_doc_id)

            rows << row
            return rows if rows.length >= limit
          end

          break if batch.length < batch_size

          offset += batch_size
        end

        rows
      end

      def search_fts_rows(query, limit:, offset:, snippet_start:, snippet_end:, snippet_tokens:)
        binds = [
          bind(snippet_start.to_s),
          bind(snippet_end.to_s),
          bind(snippet_tokens.to_i),
          bind(parse_fts_query(query))
        ]

        binds << bind(limit.to_i)
        binds << bind(offset.to_i)

        connection.exec_query(
          <<~SQL.squish,
            SELECT
              design_doc_id,
              bm25(design_doc_fts, 4.0, 3.0, 1.0, 1.0, 1.5, 0.8, 0.8) AS rank,
              snippet(design_doc_fts, -1, ?, ?, '...', ?) AS snippet
            FROM design_doc_fts
            WHERE design_doc_fts MATCH ?
            ORDER BY rank ASC, updated_at DESC, design_doc_id DESC
            LIMIT ? OFFSET ?
          SQL
          "DesignDocs::SearchIndex Search",
          binds
        ).map(&:symbolize_keys)
      end

      def exact_doc_rows(query, user:, snippet_start:, snippet_end:)
        doc_ids = query.to_s.scan(/\bDOC-(\d+)\b/i).flatten.map(&:to_i).uniq
        return [] if doc_ids.empty?

        DesignDocs::DesignDoc.visible_to(user).where(id: doc_ids).map do |design_doc|
          {
            design_doc_id: design_doc.id,
            rank: -1.0,
            snippet: "#{snippet_start}#{ERB::Util.html_escape(design_doc.display_id)}#{snippet_end}"
          }
        end
      end

      def merge_exact_doc_rows(search_rows, exact_rows)
        return search_rows if exact_rows.empty?

        exact_ids = exact_rows.map { |row| row.fetch(:design_doc_id).to_i }.to_set
        exact_rows + search_rows.reject { |row| exact_ids.include?(row.fetch(:design_doc_id).to_i) }
      end

      def visible_doc_ids(rows, user)
        ids = rows.filter_map { |row| row[:design_doc_id]&.to_i }.uniq
        return Set.new if ids.empty?

        DesignDocs::DesignDoc.visible_to(user).where(id: ids).pluck(:id).to_set
      end

      def insert(design_doc)
        connection.exec_insert(
          <<~SQL.squish,
            INSERT INTO design_doc_fts (
              display_id,
              title,
              body,
              preview_text,
              repository_text,
              owner_text,
              collaborator_text,
              design_doc_id,
              owner_user_id,
              visibility,
              state,
              created_at,
              updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          "DesignDocs::SearchIndex Insert",
          [
            bind(design_doc.display_id),
            bind(design_doc.title.to_s),
            bind(DesignDocs::AnchorMarkers.strip(design_doc.markdown.to_s)),
            bind(design_doc.preview_text.to_s),
            bind(repository_text(design_doc)),
            bind(user_text(design_doc.owner_user)),
            bind(design_doc.collaborator_users.map { |user| user_text(user) }.join(" ")),
            bind(design_doc.id),
            bind(design_doc.owner_user_id),
            bind(design_doc.visibility.to_s),
            bind(design_doc.state.to_s),
            bind(design_doc.created_at&.iso8601),
            bind(design_doc.updated_at&.iso8601)
          ]
        )
      end

      def repository_text(design_doc)
        design_doc.repositories.map { |repository| [ repository.slug, repository.owner, repository.name ].join(" ") }.join(" ")
      end

      def user_text(user)
        return "" unless user

        [ user.display_name, user.email_address ].compact.join(" ")
      end
    end
  end
end
