class OperationalLogIndex < SearchRecord
  include FtsQueryParser

  MAX_LIMIT = 100
  FALLBACK_SEARCH_SCAN_LIMIT = 1_000

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

    def search(query: nil, since: OperationalLogEvent::RETENTION.ago, until_time: nil, level: nil, role: nil, hostname: nil, app_revision: nil, limit: 50, offset: 0)
      return fallback_search(query: query, since: since, until_time: until_time, level: level, role: role, hostname: hostname, app_revision: app_revision, limit: limit, offset: offset) unless available?

      binds = []
      wheres = [ "occurred_at >= ?" ]
      binds << bind(since.iso8601(6))

      if until_time.present?
        wheres << "occurred_at <= ?"
        binds << bind(until_time.iso8601(6))
      end
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
      if app_revision.present?
        wheres << "app_revision = ?"
        binds << bind(app_revision)
      end

      binds << bind([[limit.to_i, 1].max, MAX_LIMIT].min)
      binds << bind([offset.to_i, 0].max)
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
          LIMIT ? OFFSET ?
        SQL
        "OperationalLogIndex Search",
        binds
      )

      rows.map(&:symbolize_keys)
    end

    def available?
      connection.select_value("SELECT name FROM sqlite_master WHERE name = 'operational_log_fts'").present?
    rescue ActiveRecord::StatementInvalid, SQLite3::SQLException
      false
    end

    # Repopulates the FTS table from the primary-DB events after a schema
    # rebuild (see SyrusSearchDatabaseTasks). Retention is short (6 hours)
    # so a full re-scan is cheap.
    def rebuild!
      OperationalLogEvent.where(occurred_at: OperationalLogEvent::RETENTION.ago..).find_each do |event|
        upsert(event)
      end
    end

    private

    def fallback_search(query:, since:, until_time:, level:, role:, hostname:, app_revision:, limit:, offset:)
      scope = OperationalLogEvent.where(occurred_at: since..)
      scope = scope.where(occurred_at: ..until_time) if until_time.present?
      scope = scope.where(level: level) if level.present?
      scope = scope.where(role: role) if role.present?
      scope = scope.where(hostname: hostname) if hostname.present?
      scope = scope.where(app_revision: app_revision) if app_revision.present?
      records = scope.order(occurred_at: :desc, id: :desc).limit(fallback_scan_limit(limit, offset)).to_a
      records = filter_fallback_query(records, query) if query.present?
      records.drop([ offset.to_i, 0 ].max).first([[ limit.to_i, 1 ].max, MAX_LIMIT].min).map { |event| fallback_row(event) }
    end

    def fallback_scan_limit(limit, offset)
      [[ limit.to_i, 1 ].max + [ offset.to_i, 0 ].max, FALLBACK_SEARCH_SCAN_LIMIT].min
    end

    def filter_fallback_query(records, query)
      terms = query.to_s.scan(/[[:alnum:]_.:\/-]+/).map(&:downcase).uniq
      return records if terms.empty?

      records.select do |event|
        haystack = "#{event.message} #{context_text(event.context)}".downcase
        terms.all? { |term| haystack.include?(term) }
      end
    end

    def fallback_row(event)
      {
        operational_log_event_id: event.id,
        occurred_at: event.occurred_at&.iso8601(6),
        level: event.level,
        role: event.role,
        hostname: event.hostname,
        app_revision: event.app_revision,
        pid: event.pid,
        source: event.source,
        job_id: event.job_id,
        workflow_id: event.workflow_id,
        run_id: event.run_id,
        request_id: event.request_id,
        message: event.message,
        context_text: context_text(event.context),
        context_json: event.context.to_json,
        rank: 0
      }
    end

    def context_text(context)
      context.to_h.map { |key, value| "#{key}=#{value}" }.join(" ")
    end
  end
end
