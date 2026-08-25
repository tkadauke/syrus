class OperationalLogIndex < SearchRecord
  include FtsQueryParser

  MAX_LIMIT = 100
  FALLBACK_SEARCH_SCAN_LIMIT = 1_000
  STALE_AFTER = 5.minutes
  FRESHNESS_CHECK_INTERVAL = 2.minutes
  REBUILD_BATCH_SIZE = 1_000

  class << self
    def upsert(event)
      connection.transaction do
        insert(event)
      end
    end

    def upsert_many(events, delete_ids: [], cleanup_missing: false)
      events = events.to_a
      indexed_ids = events.map(&:id)
      missing_ids = Array(delete_ids) - indexed_ids

      connection.transaction do
        delete_many(missing_ids) if cleanup_missing
        insert_many(events)
      end
    end

    def delete(event_id)
      connection.exec_delete(
        "DELETE FROM operational_log_fts WHERE rowid = ?",
        "OperationalLogIndex Delete",
        [ bind(event_id) ]
      )
    end

    def delete_many(event_ids)
      Array(event_ids).filter_map { |id| Integer(id, exception: false) }.uniq.each_slice(500) do |ids|
        next if ids.empty?

        placeholders = ([ "?" ] * ids.size).join(", ")
        connection.exec_delete(
          "DELETE FROM operational_log_fts WHERE rowid IN (#{placeholders})",
          "OperationalLogIndex Delete Many",
          ids.map { |id| bind(id) }
        )
      end
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

      ensure_fresh!

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

    # Table existence only changes via syrus:prepare_search (a separate
    # boot-time process, or an explicit reset in this process's tests/console),
    # so memoize it instead of round-tripping to sqlite_master on every search.
    def available?
      return @available if defined?(@available)

      @available = connection.select_value("SELECT name FROM sqlite_master WHERE name = 'operational_log_fts'").present?
    rescue ActiveRecord::StatementInvalid, SQLite3::SQLException
      false
    end

    def reset_availability_cache!
      remove_instance_variable(:@available) if defined?(@available)
    end

    # A local search.sqlite3 mirror only stays fresh on hosts that actively
    # consume the `indexing` queue (the multi-worker "home" tier — see
    # config/syrus_docs/multi_worker.md). Any other process attached to the
    # same data root (a "compute" tier worker, or a per-Run MCP sidecar
    # spawned as its subprocess) gets its local operational_log_fts seeded
    # once at container boot (REBUILD_HOOKS replays the retention window)
    # and never again, since IndexOperationalLogEventsJob never runs there.
    # Once that boot-time seed ages out of OperationalLogEvent::RETENTION,
    # every search silently returns zero rows even though the primary DB
    # keeps accumulating events, with no error surfaced anywhere. Detect
    # that drift here and self-heal instead of requiring an operator to
    # notice and run `OperationalLogIndex.rebuild!` by hand.
    def ensure_fresh!
      return if @next_freshness_check_at && Time.current < @next_freshness_check_at

      @next_freshness_check_at = Time.current + FRESHNESS_CHECK_INTERVAL

      primary_latest = OperationalLogEvent.maximum(:occurred_at)
      return unless primary_latest

      local_latest = connection.select_value("SELECT MAX(occurred_at) FROM operational_log_fts").presence
      local_latest_time = local_latest && Time.zone.parse(local_latest)
      return if local_latest_time && local_latest_time >= primary_latest - STALE_AFTER

      rebuild!
    end

    def reset_freshness_check!
      remove_instance_variable(:@next_freshness_check_at) if defined?(@next_freshness_check_at)
    end

    # Repopulates the FTS table from the primary-DB events after the table is
    # (re)created — first boot on a fresh search volume, a schema-drift
    # rebuild (see SyrusSearchDatabaseTasks::REBUILD_HOOKS, called from both
    # branches of #ensure_required_tables!), or a runtime drift self-heal
    # (see #ensure_fresh!, which can run synchronously inside a search call).
    # Retention is only 6 hours, but a busy instance can still have tens of
    # thousands of events in that window, so this batches through
    # upsert_many (one transaction per batch) instead of looping upsert
    # (one transaction, and one fsync, per row) — the difference between a
    # sub-second rebuild and one that blocks a search for minutes.
    def rebuild!
      OperationalLogEvent.where(occurred_at: OperationalLogEvent::RETENTION.ago..)
        .find_in_batches(batch_size: REBUILD_BATCH_SIZE) do |batch|
          upsert_many(batch, delete_ids: batch.map(&:id))
        end
    end

    private

    def insert_many(events)
      events.each_slice(50) do |batch|
        next if batch.empty?

        placeholders = batch.map { "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)" }.join(", ")
        connection.exec_insert(
          <<~SQL.squish,
            INSERT OR REPLACE INTO operational_log_fts (
              rowid,
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
            VALUES #{placeholders}
          SQL
          "OperationalLogIndex Upsert Many",
          batch.flat_map { |event| insert_binds(event) }
        )
      end
    end

    def insert(event)
      connection.exec_insert(
        <<~SQL.squish,
          INSERT OR REPLACE INTO operational_log_fts (
            rowid,
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
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        "OperationalLogIndex Upsert",
        insert_binds(event)
      )
    end

    def insert_binds(event)
      [
        bind(event.id),
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
    end

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
