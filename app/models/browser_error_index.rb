class BrowserErrorIndex < SearchRecord
  include FtsQueryParser

  MAX_LIMIT = 500

  class << self
    def upsert(event)
      connection.transaction do
        delete(event.id)
        connection.exec_insert(
          <<~SQL.squish,
            INSERT INTO browser_error_fts (
              message,
              search_text,
              browser_error_event_id,
              occurred_at,
              app_revision,
              fingerprint,
              name,
              path,
              user_id
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          "BrowserErrorIndex Upsert",
          [
            bind(event.message),
            bind(search_text(event)),
            bind(event.id),
            bind(event.occurred_at&.iso8601(6)),
            bind(event.app_revision),
            bind(event.fingerprint),
            bind(event.name),
            bind(event.path),
            bind(event.user_id)
          ]
        )
      end
    end

    def delete(event_id)
      connection.exec_delete(
        "DELETE FROM browser_error_fts WHERE browser_error_event_id = ?",
        "BrowserErrorIndex Delete",
        [ bind(event_id) ]
      )
    end

    def prune_before(cutoff)
      return unless available?

      connection.exec_delete(
        "DELETE FROM browser_error_fts WHERE occurred_at < ?",
        "BrowserErrorIndex Prune",
        [ bind(cutoff.iso8601(6)) ]
      )
    end

    def search(query:, since:, until_time: nil, app_revision: nil, limit: 100)
      return [] unless available?

      binds = []
      wheres = [ "occurred_at >= ?" ]
      binds << bind(since.iso8601(6))

      if until_time.present?
        wheres << "occurred_at <= ?"
        binds << bind(until_time.iso8601(6))
      end
      if app_revision.present?
        wheres << "app_revision = ?"
        binds << bind(app_revision)
      end
      if query.present?
        wheres << "browser_error_fts MATCH ?"
        binds << bind(parse_fts_query(query))
      end

      binds << bind([[limit.to_i, 1].max, MAX_LIMIT].min)
      connection.exec_query(
        <<~SQL.squish,
          SELECT browser_error_event_id
          FROM browser_error_fts
          WHERE #{wheres.join(" AND ")}
          ORDER BY occurred_at DESC, browser_error_event_id DESC
          LIMIT ?
        SQL
        "BrowserErrorIndex Search",
        binds
      ).map { |row| row["browser_error_event_id"] }
    rescue ActiveRecord::StatementInvalid, SQLite3::SQLException
      []
    end

    def available?
      connection.select_value("SELECT name FROM sqlite_master WHERE name = 'browser_error_fts'").present?
    rescue ActiveRecord::StatementInvalid, SQLite3::SQLException
      false
    end

    def rebuild!
      BrowserErrorEvent.where(occurred_at: BrowserErrorEvent::RETENTION.ago..).find_each do |event|
        upsert(event)
      end
    end

    def search_text(event)
      [
        event.name,
        event.path,
        event.url,
        event.fingerprint,
        event.stack,
        event.component_stack,
        event.user_agent,
        event.route_params,
        event.feature_flags,
        event.recent_api_requests,
        event.recent_errors,
        event.metadata
      ].map { |value| value.respond_to?(:to_json) ? value.to_json : value.to_s }.join(" ")
    end
  end
end
