# Shared query-param normalization, disabled-response shape, and log-row
# rendering for the two operational-log MCP tools: the workflow/agent-insight
# `SyrusDev::ReadSyrusLogsTool` and the admin-chat `Mcp::Tools::AdminReadOperationalLogsTool`.
# Both wrap `OperationalLogIndex.search` with the same query/since/level/role/
# hostname/limit shape; keeping the normalization and rendering here avoids the
# two tools drifting out of sync.
module OperationalLogSearch
  INPUT_SCHEMA_PROPERTIES = {
    query: {
      type: "string",
      description: "Optional FTS query matched against the redacted message and context text."
    },
    since: {
      type: "string",
      description: "ISO8601 timestamp or relative duration like 30m, 2h, or 1d. Defaults to 1h and is capped by retention."
    },
    level: {
      type: "string",
      enum: OperationalLogEvent::LEVELS,
      description: "Optional log level filter."
    },
    role: {
      type: "string",
      description: "Optional process role filter."
    },
    hostname: {
      type: "string",
      description: "Optional hostname filter."
    },
    limit: {
      type: "integer",
      description: "Maximum rows to return, 1..100. Defaults to 50."
    }
  }.freeze

  module_function

  def disabled_response
    MCP::Tool::Response.new([
      {
        type: "text",
        text: JSON.generate(
          {
            enabled: false,
            error: "operational_log_indexing_disabled",
            message: "Operational log indexing is disabled for this instance or no tkadauke/syrus repository/fork is registered."
          }
        )
      }
    ])
  end

  def search_response(query:, since:, level:, role:, hostname:, limit:)
    normalized = normalize_params(query: query, since: since, level: level, role: role, hostname: hostname, limit: limit)
    return Mcp::Tools.invalid(normalized[:error]) if normalized[:error]

    rows = OperationalLogging.suppress do
      OperationalLogIndex.search(**normalized.fetch(:params))
    end

    MCP::Tool::Response.new([
      {
        type: "text",
        text: JSON.generate(
          {
            enabled: true,
            retention_seconds: OperationalLogEvent::RETENTION.to_i,
            count: rows.size,
            logs: rows.map { |row| log_payload(row) }
          }
        )
      }
    ])
  end

  def normalize_params(query:, since:, level:, role:, hostname:, limit:)
    level_s = Mcp::Tools.utf8(level).strip.downcase.presence
    return { error: "level must be one of: #{OperationalLogEvent::LEVELS.join(', ')}" } if level_s && !OperationalLogEvent::LEVELS.include?(level_s)

    {
      params: {
        query: Mcp::Tools.utf8(query).strip.safe_byteslice(0, 500).presence,
        since: parse_since(since),
        level: level_s,
        role: Mcp::Tools.utf8(role).strip.safe_byteslice(0, 100).presence,
        hostname: Mcp::Tools.utf8(hostname).strip.safe_byteslice(0, 255).presence,
        limit: [[ limit.to_i, 1 ].max, OperationalLogIndex::MAX_LIMIT].min
      }
    }
  rescue ArgumentError => e
    { error: e.message }
  end

  def parse_since(value)
    retention_floor = OperationalLogEvent::RETENTION.ago
    parsed = if value.blank?
      1.hour.ago
    elsif (match = value.to_s.match(/\A(\d+)([mhd])\z/i))
      amount = match[1].to_i
      unit = match[2].downcase
      amount.public_send({ "m" => :minutes, "h" => :hours, "d" => :days }.fetch(unit)).ago
    else
      Time.zone.parse(value.to_s)
    end
    raise ArgumentError, "since must be an ISO8601 timestamp or relative duration like 30m, 2h, or 1d" unless parsed

    [ parsed, retention_floor ].max
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
      message: row[:message],
      context: context_payload(row[:context_json])
    }.compact
  end

  def context_payload(context_json)
    JSON.parse(context_json.to_s)
  rescue JSON::ParserError
    {}
  end
end
