module Admin
  class OperationalLogsPayload
    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE = OperationalLogIndex::MAX_LIMIT
    ROLES = %w[ web worker ].freeze
    REVISION_SCOPES = %w[ current all ].freeze

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
        retention_seconds: OperationalLogEvent::RETENTION.to_i,
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
        retention_seconds: OperationalLogEvent::RETENTION.to_i,
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
          since: since_time,
          until_time: until_time,
          level: level,
          role: role,
          hostname: hostname,
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
        since: since_time.iso8601,
        until: until_time&.iso8601,
        level: level,
        role: role,
        hostname: hostname
      }
    end

    def query
      text_value(:query)
    end

    def level
      value = text_value(:level)&.downcase
      return nil unless value
      raise ArgumentError, "level must be one of: #{OperationalLogEvent::LEVELS.join(', ')}" unless OperationalLogEvent::LEVELS.include?(value)

      value
    end

    def role
      value = text_value(:role)&.downcase
      return nil unless value
      raise ArgumentError, "role must be one of: #{ROLES.join(', ')}" unless ROLES.include?(value)

      value
    end

    def hostname
      text_value(:hostname)&.safe_byteslice(0, 255)
    end

    def since_time
      parsed_time(:since, default: 1.hour.ago, floor: OperationalLogEvent::RETENTION.ago)
    end

    def until_time
      parsed_time(:until, default: nil, floor: OperationalLogEvent::RETENTION.ago)
    end

    def parsed_time(key, default:, floor:)
      value = utf8_param(key)
      value = raw_filter_value(key) if value.blank?
      parsed = if value.blank?
        default
      elsif value.is_a?(Hash)
        duration_value(value).ago
      elsif (match = value.match(/\A(\d+)([mhd])\z/i))
        amount = match[1].to_i
        amount.public_send({ "m" => :minutes, "h" => :hours, "d" => :days }.fetch(match[2].downcase)).ago
      else
        Time.zone.parse(value)
      end
      return nil if parsed.nil? && default.nil?
      raise ArgumentError, "#{key} must be an ISO8601 timestamp or relative duration like 30m, 2h, or 1d" unless parsed

      [ parsed, floor ].max
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

    def raw_filter_value(key)
      @raw_filter_values ||= filter_definition.flat_filters(params).symbolize_keys
      @raw_filter_values[key.to_sym]
    end

    def text_value(key)
      Mcp::Tools.utf8(raw_filter_value(key)).strip.safe_byteslice(0, 500).presence
    end

    def duration_value(value)
      amount = Integer(value["n"] || value[:n] || 0)
      unit = (value["unit"] || value[:unit]).to_s
      amount.public_send(unit)
    end
  end
end
