module SyrusDev
  class PerformancePayload
    DEFAULT_LIMIT = 500

    def initialize(params: {})
      @params = params
    end

    def as_json(*)
      raw_events = PerformanceLogging::Store.recent(limit: limit)
      events = filter_events(raw_events)
      summaries = summaries_payload(events)
      current_summaries = summaries_payload(raw_events.select { |event| event["app_revision"] == current_revision })
      baseline_revision = previous_revision(raw_events)
      {
        enabled: Feature.enabled?(PerformanceLogging::FEATURE_SLUG),
        current_revision: current_revision,
        revision_scope: revision_scope,
        thresholds: PerformanceLogging.thresholds,
        storage: storage_payload,
        baseline: baseline_payload(baseline_revision, raw_events, current_summaries),
        summaries: summaries,
        events: events
      }
    end

    private

    attr_reader :params

    def limit
      raw = Integer(params[:limit], exception: false) || DEFAULT_LIMIT
      PerformanceLogging::Store.clamp_limit(raw)
    end

    def storage_payload
      {
        kind: "performance_log_events",
        max_events: PerformanceLogging::Store::MAX_EVENTS,
        expires_in_seconds: PerformanceLogEvent::RETENTION.to_i,
        buffered: Observability::EventSink.stats.dig(:buffered, :performance).to_i,
        dropped: Observability::EventSink.stats.dig(:dropped, :performance).to_i
      }
    end

    def filter_events(events)
      return events if revision_scope == "all"

      events.select { |event| event["app_revision"] == current_revision }
    end

    def revision_scope
      params[:revision_scope].to_s == "all" ? "all" : "current"
    end

    def current_revision
      SyrusVersion.current
    end

    def summaries_payload(events)
      {
        slow_requests: grouped_slow_requests(events),
        slow_jobs: grouped_slow_jobs(events),
        slow_phases: grouped_slow_phases(events),
        browser_traces: grouped_browser_traces(events),
        sql_fingerprints: grouped_sql_fingerprints(events)
      }
    end

    def baseline_payload(baseline_revision, raw_events, current_summaries)
      return { revision: nil, comparisons: empty_comparisons } unless baseline_revision

      baseline_summaries = summaries_payload(events_for_revision(raw_events, baseline_revision))
      {
        revision: baseline_revision,
        comparisons: {
          slow_requests: compare_summary_rows(current_summaries[:slow_requests], baseline_summaries[:slow_requests], :request_key),
          slow_jobs: compare_summary_rows(current_summaries[:slow_jobs], baseline_summaries[:slow_jobs], :job_key),
          slow_phases: compare_summary_rows(current_summaries[:slow_phases], baseline_summaries[:slow_phases], :phase_key),
          browser_traces: compare_summary_rows(current_summaries[:browser_traces], baseline_summaries[:browser_traces], :browser_trace_key),
          sql_fingerprints: compare_summary_rows(current_summaries[:sql_fingerprints], baseline_summaries[:sql_fingerprints], :sql_fingerprint_key)
        }
      }
    end

    def empty_comparisons
      {
        slow_requests: [],
        slow_jobs: [],
        slow_phases: [],
        browser_traces: [],
        sql_fingerprints: []
      }
    end

    def previous_revision(raw_events)
      revision = raw_events
        .filter_map { |event| event["app_revision"].presence }
        .reject { |revision| revision == current_revision }
        .uniq
        .first
      revision.presence || previous_persisted_revision
    end

    def previous_persisted_revision
      PerformanceLogEvent
        .where(occurred_at: PerformanceLogEvent::RETENTION.ago..)
        .where.not(app_revision: [ nil, "", current_revision ])
        .group(:app_revision)
        .maximum(:occurred_at)
        .max_by { |_revision, occurred_at| occurred_at }
        &.first
    end

    def events_for_revision(raw_events, revision)
      events = raw_events.select { |event| event["app_revision"] == revision }
      persisted = PerformanceLogEvent
        .where(app_revision: revision, occurred_at: PerformanceLogEvent::RETENTION.ago..)
        .recent_first
        .limit(limit)
        .map(&:as_event_hash)
      (events + persisted)
        .uniq { |event| [ event["occurred_at"], event["event"], event["request_id"], event["trace_id"], event["active_job_id"], event["job_class"], event["phase"], event["path"], event["fingerprint"] ] }
        .sort_by { |event| event["occurred_at"].to_s }
        .last(limit)
        .reverse
    end

    def compare_summary_rows(current_rows, baseline_rows, key_method)
      baseline_by_key = baseline_rows.index_by { |row| send(key_method, row) }

      current_rows.filter_map do |current|
        key = send(key_method, current)
        baseline = baseline_by_key[key]
        current_avg = current[:average_duration_ms].to_f
        baseline_avg = baseline&.dig(:average_duration_ms).to_f
        next if baseline && baseline_avg <= 0 && current_avg <= 0

        {
          key: key,
          label: comparison_label(current),
          current_average_duration_ms: current[:average_duration_ms],
          baseline_average_duration_ms: baseline&.dig(:average_duration_ms),
          delta_average_duration_ms: baseline ? (current_avg - baseline_avg).round(1) : current_avg.round(1),
          delta_percent: baseline && baseline_avg.positive? ? (((current_avg - baseline_avg) / baseline_avg) * 100.0).round(1) : nil,
          current_count: current[:count],
          baseline_count: baseline&.dig(:count),
          status: comparison_status(current_avg, baseline_avg, baseline.present?)
        }
      end.sort_by { |row| [ comparison_status_rank(row[:status]), -row[:delta_average_duration_ms].to_f ] }.first(20)
    end

    def request_key(row)
      [ row[:method], comparable_path(row[:path]), row[:controller], row[:action] ].join(" ")
    end

    def job_key(row)
      [ row[:job_class], row[:queue_name] ].join(" ")
    end

    def phase_key(row)
      row[:phase].to_s
    end

    def browser_trace_key(row)
      [ row[:name], comparable_path(row[:path]) ].join(" ")
    end

    def sql_fingerprint_key(row)
      row[:fingerprint].to_s
    end

    def comparison_label(row)
      comparable_path(row[:path]).presence || row[:job_class].presence || row[:phase].presence || row[:name].presence || row[:fingerprint].to_s.truncate(120)
    end

    def comparable_path(path)
      path.to_s.split("?").first
    end

    def comparison_status(current_avg, baseline_avg, baseline_present)
      return "new" unless baseline_present
      return "unchanged" if baseline_avg <= 0

      ratio = current_avg / baseline_avg
      return "regressed" if current_avg - baseline_avg >= 250.0 && ratio >= 1.5
      return "improved" if baseline_avg - current_avg >= 250.0 && ratio <= 0.75

      "unchanged"
    end

    def comparison_status_rank(status)
      { "regressed" => 0, "new" => 1, "improved" => 2, "unchanged" => 3 }.fetch(status, 4)
    end

    def grouped_slow_requests(events)
      grouped = events.select { |event| event["event"] == PerformanceLogging::SLOW_REQUEST_EVENT }
        .group_by { |event| [ event["method"], event["path"], event["controller"], event["action"] ] }

      grouped.map do |(method, path, controller, action), rows|
        durations = rows.map { |event| event["duration_ms"].to_f }
        {
          method: method,
          path: path,
          controller: controller,
          action: action,
          count: rows.size,
          total_duration_ms: durations.sum.round(1),
          average_duration_ms: average(durations),
          max_duration_ms: durations.max&.round(1),
          average_sql_count: average(rows.map { |event| event["sql_count"].to_i }),
          average_sql_duration_ms: average(rows.map { |event| event["sql_duration_ms"].to_f }),
          last_seen_at: rows.map { |event| event["occurred_at"] }.compact.max
        }
      end.sort_by { |row| [ -row[:total_duration_ms].to_f, -row[:count] ] }
    end

    def grouped_slow_jobs(events)
      grouped = events.select { |event| event["event"] == PerformanceLogging::SLOW_JOB_EVENT }
        .group_by { |event| [ event["job_class"], event["queue_name"] ] }

      grouped.map do |(job_class, queue_name), rows|
        durations = rows.map { |event| event["duration_ms"].to_f }
        {
          job_class: job_class,
          queue_name: queue_name,
          count: rows.size,
          total_duration_ms: durations.sum.round(1),
          average_duration_ms: average(durations),
          max_duration_ms: durations.max&.round(1),
          average_sql_count: average(rows.map { |event| event["sql_count"].to_i }),
          average_sql_duration_ms: average(rows.map { |event| event["sql_duration_ms"].to_f }),
          slow_sql_count: rows.sum { |event| event["slow_sql_count"].to_i },
          last_seen_at: rows.map { |event| event["occurred_at"] }.compact.max,
          recent_active_job_id: rows.first["active_job_id"],
          recent_trigger_reasons: Array(rows.first["trigger_reasons"])
        }
      end.sort_by { |row| [ -row[:total_duration_ms].to_f, -row[:count] ] }
    end

    def grouped_slow_phases(events)
      grouped = events.select { |event| event["event"] == PerformanceLogging::SLOW_PHASE_EVENT }
        .group_by { |event| event["phase"] }

      grouped.map do |phase, rows|
        durations = rows.map { |event| event["duration_ms"].to_f }
        {
          phase: phase,
          count: rows.size,
          total_duration_ms: durations.sum.round(1),
          average_duration_ms: average(durations),
          max_duration_ms: durations.max&.round(1),
          last_seen_at: rows.map { |event| event["occurred_at"] }.compact.max,
          recent_metadata: rows.first["metadata"]
        }
      end.sort_by { |row| [ -row[:total_duration_ms].to_f, -row[:count] ] }
    end

    def grouped_browser_traces(events)
      grouped = events.select { |event| event["event"] == PerformanceLogging::BROWSER_TRACE_EVENT }
        .group_by { |event| [ event["name"], event["path"] ] }

      grouped.map do |(name, path), rows|
        durations = rows.map { |event| event["duration_ms"].to_f }
        api_requests = rows.flat_map { |event| Array(event["api_requests"]) }
        api_durations = api_requests.map { |request| request["duration_ms"].to_f }
        spans = rows.flat_map { |event| Array(event["spans"]) }
        span_durations = spans.map { |span| span["duration_ms"].to_f }
        {
          name: name,
          path: path,
          count: rows.size,
          total_duration_ms: durations.sum.round(1),
          average_duration_ms: average(durations),
          max_duration_ms: durations.max&.round(1),
          average_api_duration_ms: average(api_durations),
          max_api_duration_ms: api_durations.max&.round(1),
          average_span_duration_ms: average(span_durations),
          max_span_duration_ms: span_durations.max&.round(1),
          recent_spans: spans.first(8),
          recent_api_request_ids: api_requests.filter_map { |request| request["request_id"] }.first(6),
          recent_metadata: rows.first["metadata"],
          last_seen_at: rows.map { |event| event["occurred_at"] }.compact.max
        }
      end.sort_by { |row| [ -row[:total_duration_ms].to_f, -row[:count] ] }
    end

    def grouped_sql_fingerprints(events)
      rows = []
      events.each do |event|
        if event["event"] == PerformanceLogging::SLOW_SQL_EVENT && event["fingerprint"].present?
          rows << {
            "fingerprint" => event["fingerprint"],
            "sample_sql" => event["sql"],
            "name" => event["name"],
            "count" => 1,
            "total_duration_ms" => event["duration_ms"].to_f,
            "max_duration_ms" => event["duration_ms"].to_f
          }
        end
        Array(event["top_sql_fingerprints"]).each { |entry| rows << entry }
      end

      grouped = rows.group_by { |row| row["fingerprint"] }
      grouped.map do |fingerprint, entries|
        total = entries.sum { |entry| entry["total_duration_ms"].to_f }
        count = entries.sum { |entry| entry["count"].to_i }
        {
          fingerprint: fingerprint,
          sample_sql: entries.find { |entry| entry["sample_sql"].present? }&.fetch("sample_sql"),
          name: entries.find { |entry| entry["name"].present? }&.fetch("name"),
          count: count,
          total_duration_ms: total.round(1),
          average_duration_ms: count.positive? ? (total / count).round(1) : nil,
          max_duration_ms: entries.map { |entry| entry["max_duration_ms"].to_f }.max&.round(1)
        }
      end.sort_by { |row| [ -row[:total_duration_ms].to_f, -row[:count] ] }
    end

    def average(values)
      values = values.compact
      return nil if values.empty?

      (values.sum.to_f / values.size).round(1)
    end
  end
end
