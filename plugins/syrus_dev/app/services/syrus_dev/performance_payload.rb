module SyrusDev
  class PerformancePayload
    DEFAULT_LIMIT = 500

    def initialize(params: {})
      @params = params
    end

    def as_json(*)
      raw_events = filtered_events(PerformanceLogging::Store.recent(limit: limit))
      current_events = raw_events.select { |event| event["app_revision"] == current_revision }
      events = revision_scope == "all" ? raw_events : current_events
      summaries = summaries_payload(events)
      current_summaries = revision_scope == "all" ? summaries_payload(current_events) : summaries
      baseline_revision = previous_revision(raw_events)
      {
        enabled: Feature.enabled?(PerformanceLogging::FEATURE_SLUG),
        current_revision: current_revision,
        revision_scope: revision_scope,
        filter: filter_payload,
        filter_schema: filter_schema,
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

    def revision_scope
      params[:revision_scope].to_s == "all" ? "all" : "current"
    end

    def filter_payload
      chips = []
      chips << { field: "app_revision", op: "is", value: app_revision_filter } if app_revision_filter.present?
      chips << { field: "since", op: "is", value: since_param } if since_param.present?
      chips << { field: "until", op: "is", value: until_param } if until_param.present?
      chips << { field: "revision_scope", op: "is", value: revision_scope }
      %i[event_name request_id trace_id job_class path controller action sql_fingerprint].each do |field|
        value = params[field]
        chips << { field: field.to_s, op: "is", value: value.to_s } if value.present?
      end
      { and: chips }
    end

    def filter_schema
      [
        { field: "app_revision", label: "SHA", bucket: "text", operators: [ "is" ], expansions: { placeholder: current_revision.first(12) } },
        { field: "since", label: "Since", bucket: "text", operators: [ "is" ], expansions: { placeholder: "1h" } },
        { field: "until", label: "Until", bucket: "text", operators: [ "is" ], expansions: { placeholder: Time.current.iso8601 } },
        { field: "revision_scope", label: "Revision scope", bucket: "enum", operators: [ "is" ], values: [
          { value: "current", label: "Current SHA" },
          { value: "all", label: "All SHAs" }
        ] },
        { field: "event_name", label: "Event", bucket: "text", operators: [ "is" ], expansions: { placeholder: PerformanceLogging::SLOW_REQUEST_EVENT } },
        { field: "request_id", label: "Request ID", bucket: "text", operators: [ "is" ] },
        { field: "trace_id", label: "Trace ID", bucket: "text", operators: [ "is" ] },
        { field: "job_class", label: "Job class", bucket: "text", operators: [ "is" ] },
        { field: "path", label: "Path", bucket: "text", operators: [ "is" ], expansions: { placeholder: "/api/v1/app/..." } },
        { field: "controller", label: "Controller", bucket: "text", operators: [ "is" ] },
        { field: "action", label: "Action", bucket: "text", operators: [ "is" ] },
        { field: "sql_fingerprint", label: "SQL fingerprint", bucket: "text", operators: [ "is" ] }
      ]
    end

    def current_revision
      SyrusVersion.current
    end

    def filtered_events(events)
      events.select do |event|
        matches_app_revision?(event) &&
          matches_since?(event) &&
          matches_until?(event) &&
          matches_text_filter?(event, :event_name, event_type(event)) &&
          matches_text_filter?(event, :request_id, event["request_id"]) &&
          matches_text_filter?(event, :trace_id, event["trace_id"]) &&
          matches_text_filter?(event, :job_class, event["job_class"]) &&
          matches_text_filter?(event, :path, event["path"]) &&
          matches_text_filter?(event, :controller, event["controller"]) &&
          matches_text_filter?(event, :action, event["action"]) &&
          matches_sql_fingerprint?(event)
      end
    end

    def app_revision_filter
      params[:app_revision].presence
    end

    def since_param
      params[:since].presence
    end

    def until_param
      params[:until].presence
    end

    def since_time
      @since_time ||= parse_time_filter(since_param, default_unit: "seconds_ago")
    end

    def until_time
      @until_time ||= parse_time_filter(until_param, default_unit: "absolute")
    end

    def matches_app_revision?(event)
      app_revision_filter.blank? || event["app_revision"].to_s.start_with?(app_revision_filter.to_s)
    end

    def matches_since?(event)
      since_time.blank? || event_time(event) >= since_time
    end

    def matches_until?(event)
      until_time.blank? || event_time(event) <= until_time
    end

    def matches_text_filter?(event, key, value)
      filter = params[key].to_s.strip
      filter.blank? || value.to_s.include?(filter)
    end

    def matches_sql_fingerprint?(event)
      filter = params[:sql_fingerprint].to_s.strip
      return true if filter.blank?

      event["fingerprint"].to_s.include?(filter) ||
        Array(event["top_sql_fingerprints"]).any? { |entry| entry["fingerprint"].to_s.include?(filter) }
    end

    def event_time(event)
      Time.zone.parse(event["occurred_at"].to_s)
    rescue ArgumentError, TypeError
      Time.zone.at(0)
    end

    def parse_time_filter(value, default_unit:)
      return if value.blank?

      text = value.to_s.strip
      if (match = text.match(/\A(\d+)(m|h|d)\z/i))
        amount = match[1].to_i
        unit = match[2].downcase
        return amount.minutes.ago if unit == "m"
        return amount.hours.ago if unit == "h"
        return amount.days.ago if unit == "d"
      end

      return Time.zone.at(Time.current.to_i - text.to_i) if default_unit == "seconds_ago" && text.match?(/\A\d+\z/)

      Time.zone.parse(text)
    rescue ArgumentError, TypeError
      nil
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
        .reorder(occurred_at: :desc, id: :desc)
        .limit(1)
        .pick(:app_revision)
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
      grouped = events.select { |event| event_type(event) == PerformanceLogging::SLOW_REQUEST_EVENT }
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
      grouped = events.select { |event| event_type(event) == PerformanceLogging::SLOW_JOB_EVENT }
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
      grouped = events.select { |event| event_type(event) == PerformanceLogging::SLOW_PHASE_EVENT }
        .group_by { |event| phase_label(event) }

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
      grouped = events.select { |event| event_type(event) == PerformanceLogging::BROWSER_TRACE_EVENT }
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
        if event_type(event) == PerformanceLogging::SLOW_SQL_EVENT && event["fingerprint"].present?
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

    def event_type(event)
      event["event"].presence || event["event_name"].presence
    end

    def phase_label(event)
      event["phase"].presence ||
        event["name"].presence ||
        metadata_value(event, "phase") ||
        metadata_value(event, "name") ||
        plugin_phase_label(event) ||
        "(unknown phase)"
    end

    def metadata_value(event, key)
      metadata = event["metadata"]
      return unless metadata.respond_to?(:[])

      metadata[key].presence || metadata[key.to_sym].presence
    end

    def plugin_phase_label(event)
      extension_point = metadata_value(event, "extension_point")
      operation = metadata_value(event, "operation") || metadata_value(event, "op")
      return unless extension_point.present? && operation.present?

      "plugin.#{extension_point}.#{operation}"
    end
  end
end
