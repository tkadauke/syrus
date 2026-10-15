module Admin
  class OperationalLogsPayload
    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE = OperationalLogIndex::MAX_LIMIT
    ROLES = %w[ web worker ].freeze
    REVISION_SCOPES = %w[ current all ].freeze
    SORTS = OperationalLogIndex::SORTS.keys.freeze

    def initialize(params: {})
      @params = params
    end

    def as_json(*)
      return disabled_payload unless OperationalLogging.enabled_for_instance?

      Observability::EventSink.flush!(kinds: [ :operational ])
      normalized = normalized_params
      rows = OperationalLogIndex.search(**normalized.fetch(:search_params))
      has_next_page = rows.size > normalized.fetch(:per_page)
      visible_rows = rows.first(normalized.fetch(:per_page))

      {
        enabled: true,
        retention_seconds: (OperationalLogEvent.retention_window || 0).to_i,
        current_revision: current_revision,
        revision_scope: normalized.fetch(:revision_scope),
        filter_schema: filter_definition.schema,
        filter: filter_tree,
        filters: normalized.fetch(:filters),
        pagination: {
          page: normalized.fetch(:page),
          per_page: normalized.fetch(:per_page),
          has_next_page: has_next_page,
          has_previous_page: normalized.fetch(:page) > 1,
          next_page: has_next_page ? normalized.fetch(:page) + 1 : nil,
          previous_page: normalized.fetch(:page) > 1 ? normalized.fetch(:page) - 1 : nil
        },
        logs: visible_rows.map { |row| log_payload(row) }
      }
    end

    private

    attr_reader :params

    def disabled_payload
      {
        enabled: false,
        error: {
          code: "operational_log_indexing_disabled",
          message: "Operational log indexing is disabled for this instance."
        },
        retention_seconds: (OperationalLogEvent.retention_window || 0).to_i,
        current_revision: current_revision,
        revision_scope: revision_scope,
        filter_schema: filter_definition.schema,
        filter: filter_tree,
        filters: {},
        pagination: {
          page: page,
          per_page: per_page,
          has_next_page: false,
          has_previous_page: false,
          next_page: nil,
          previous_page: nil
        },
        logs: []
      }
    end

    def normalized_params
      {
        revision_scope: revision_scope,
        page: page,
        per_page: per_page,
        filters: filters_payload,
        search_params: {
          query: query,
          since: search_floor,
          until_time: nil,
          time_filters: time_filters,
          level: enum_filter(:level, OperationalLogEvent::LEVELS),
          role: enum_filter(:role, ROLES),
          hostname: text_filter(:hostname, max_bytes: 255),
          sort: sort,
          direction: direction,
          app_revision: revision_scope == "current" ? current_revision : nil,
          limit: per_page + 1,
          offset: (page - 1) * per_page
        }
      }
    end

    def filters_payload
      @filters_payload ||= filter_definition.flat_filters(params).symbolize_keys
      {
        query: query,
        since: display_time(:since)&.iso8601,
        until: display_time(:until)&.iso8601,
        level: filter_value(:level),
        role: filter_value(:role),
        hostname: filter_value(:hostname),
        sort: sort,
        direction: direction
      }
    end

    def query
      text_value(:query)
    end

    def search_floor
      OperationalLogEvent.retention_floor
    end

    def time_filters
      filter_chips.filter_map do |chip|
        next unless chip.field.in?(%w[since until])

        { op: chip.op, value: chip.value }
      end
    end

    def display_time(key)
      chip = filter_chip(key)
      return nil unless chip

      bounds = time_bounds(chip.op, chip.value)
      key.to_sym == :since ? bounds.first : bounds.last
    end

    def page
      [ Integer(params[:page], exception: false).to_i, 1 ].max
    end

    def per_page
      raw = Integer(raw_filter_value(:per_page).presence || params[:per], exception: false) || DEFAULT_PER_PAGE
      [[raw, 1].max, MAX_PER_PAGE].min
    end

    def revision_scope
      value = raw_filter_value(:revision_scope).to_s
      REVISION_SCOPES.include?(value) ? value : "current"
    end

    def current_revision
      SyrusVersion.current
    end

    def sort
      value = utf8_param(:sort)
      SORTS.include?(value) ? value : "time"
    end

    def direction
      utf8_param(:direction) == "asc" ? "asc" : "desc"
    end

    def log_payload(row)
      {
        id: row[:operational_log_event_id],
        occurred_at: row[:occurred_at],
        level: row[:level],
        role: row[:role],
        hostname: row[:hostname],
        app_revision: row[:app_revision],
        pid: row[:pid],
        source: row[:source],
        job_id: row[:job_id],
        workflow_id: row[:workflow_id],
        run_id: row[:run_id],
        request_id: row[:request_id],
        message: redacted_string(row[:message], OperationalLogging::MAX_MESSAGE_BYTES),
        context: redacted_context(row[:context_json])
      }.compact
    end

    def redacted_context(context_json)
      JSON.parse(context_json.to_s).to_h.transform_values { |value| redacted_string(value, 1_000) }
    rescue JSON::ParserError
      {}
    end

    def redacted_string(value, limit)
      OperationalLogging.redact(Mcp::Tools.utf8(value).gsub(/[[:space:]]+/, " ").strip).safe_byteslice(0, limit)
    end

    def utf8_param(key)
      Mcp::Tools.utf8(params[key]).strip
    end

    def filter_definition
      Admin::EventLogFilterDefinitions.operational_logs
    end

    def filter_tree
      @filter_tree ||= filter_definition.filter_tree(params)
    end

    def filter_chips
      @filter_chips ||= filter_definition.chips(params)
    end

    def filter_chip(key)
      filter_chips.find { |chip| chip.field == key.to_s }
    end

    def raw_filter_value(key)
      @raw_filter_values ||= filter_definition.flat_filters(params).symbolize_keys
      @raw_filter_values[key.to_sym]
    end

    def text_value(key)
      Mcp::Tools.utf8(raw_filter_value(key)).strip.safe_byteslice(0, 500).presence
    end

    def filter_value(key)
      filter_chip(key)&.value
    end

    def enum_filter(key, allowed_values)
      chip = filter_chip(key)
      return nil unless chip

      values = Array(chip.value).map { |value| Mcp::Tools.utf8(value).strip.downcase }.compact_blank
      invalid_values = values - allowed_values
      raise ArgumentError, "#{key} must be one of: #{allowed_values.join(', ')}" if invalid_values.any?

      { op: chip.op, value: chip.op.in?(%w[is_one_of is_none_of]) ? values : values.first }
    end

    def text_filter(key, max_bytes:)
      chip = filter_chip(key)
      return nil unless chip

      { op: chip.op, value: Mcp::Tools.utf8(chip.value).strip.safe_byteslice(0, max_bytes) }
    end

    def time_bounds(op, value)
      case op.to_s
      when "within_last", "after"
        [ parsed_time_value(value), nil ]
      when "more_than_ago", "before"
        [ nil, parsed_time_value(value) ]
      when "between"
        range = Array(value)
        [ parsed_time_value(range.first), parsed_time_value(range.last) ]
      else
        [ nil, nil ]
      end
    end

    def parsed_time_value(value)
      parsed = if value.is_a?(Hash)
        duration_value(value).ago
      elsif (match = value.to_s.match(/\A(\d+)([mhd])\z/i))
        amount = match[1].to_i
        amount.public_send({ "m" => :minutes, "h" => :hours, "d" => :days }.fetch(match[2].downcase)).ago
      else
        Time.zone.parse(value.to_s)
      end
      raise ArgumentError, "time filters must be ISO8601 timestamps or relative durations like 30m, 2h, or 1d" unless parsed

      [ parsed, search_floor ].max
    end

    def duration_value(value)
      amount = Integer(value["n"] || value[:n] || 0)
      unit = (value["unit"] || value[:unit]).to_s
      amount.public_send(unit)
    end
  end
end
