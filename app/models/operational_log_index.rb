class OperationalLogIndex < SearchRecord
  include FtsQueryParser

  MAX_LIMIT = 100

  class << self
    def upsert(event)
      connection.transaction do
        delete(event.id)
        connection.exec_insert(
          <<~SQL.squish,
            INSERT INTO operational_log_fts (
              message,
              context_text,
              context_json,
              operational_log_event_id,
              occurred_at,
              level,
              role,
              hostname,
              app_revision,
              pid,
              source,
              job_id,
              workflow_id,
              run_id,
              request_id
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          "OperationalLogIndex Upsert",
          [
            bind(event.message),
            bind(context_text(event.context)),
            bind(event.context.to_json),
            bind(event.id),
            bind(event.occurred_at&.iso8601(6)),
            bind(event.level),
            bind(event.role),
            bind(event.hostname),
            bind(event.app_revision),
            bind(event.pid),
            bind(event.source),
            bind(event.job_id),
            bind(event.workflow_id),
            bind(event.run_id),
            bind(event.request_id)
          ]
        )
      end
    end

    def delete(event_id)
      connection.exec_delete(
        "DELETE FROM operational_log_fts WHERE operational_log_event_id = ?",
        "OperationalLogIndex Delete",
        [ bind(event_id) ]
      )
    end

    def prune_before(cutoff)
      connection.exec_delete(
        "DELETE FROM operational_log_fts WHERE occurred_at < ?",
        "OperationalLogIndex Prune",
        [ bind(cutoff.iso8601(6)) ]
      )
    end

    def search(query: nil, since: OperationalLogEvent::RETENTION.ago, level: nil, role: nil, hostname: nil, limit: 50)
      binds = []
      wheres = [ "occurred_at >= ?" ]
      binds << bind(since.iso8601(6))

      if query.present?
        wheres << "operational_log_fts MATCH ?"
        binds << bind(parse_fts_query(query))
      end
      if level.present?
        wheres << "level = ?"
        binds << bind(level)
      end
      if role.present?
        wheres << "role = ?"
        binds << bind(role)
      end
      if hostname.present?
        wheres << "hostname = ?"
        binds << bind(hostname)
      end

      binds << bind([[limit.to_i, 1].max, MAX_LIMIT].min)
      rows = connection.exec_query(
        <<~SQL.squish,
          SELECT
            operational_log_event_id,
            occurred_at,
            level,
            role,
            hostname,
            app_revision,
            pid,
            source,
            job_id,
            workflow_id,
            run_id,
            request_id,
            message,
            context_text,
            context_json,
            #{query.present? ? "bm25(operational_log_fts)" : "0"} AS rank
          FROM operational_log_fts
          WHERE #{wheres.join(" AND ")}
          ORDER BY occurred_at DESC, operational_log_event_id DESC
          LIMIT ?
        SQL
        "OperationalLogIndex Search",
        binds
      )

      rows.map(&:symbolize_keys)
    end

    private

    def context_text(context)
      context.to_h.map { |key, value| "#{key}=#{value}" }.join(" ")
    end
  end
end
