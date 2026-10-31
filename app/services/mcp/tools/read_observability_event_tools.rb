require "mcp"

module Mcp::Tools
  module ReadObservabilityEventTools
    MAX_EVENTS = 100

    private

    def read_events(server_context:, payload_class:, **filters)
      return Mcp::Tools.unauthorized("Observability access required") unless observability_authorized?(server_context)

      params = filters.compact_blank.merge(per_page: capped_limit(filters[:limit]))
      payload = payload_class.new(params: params).as_json.deep_dup
      payload[:events] = Array(payload[:events]).map { |event| event.except(:actions, "actions") }
      Mcp::Tools.success(CommandRedactor.redact_value(payload))
    rescue StandardError => e
      Rails.logger.error("[#{name}] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def capped_limit(value)
      raw = Integer(value, exception: false) || Admin::EventLogPayload::DEFAULT_PER_PAGE
      raw.clamp(1, MAX_EVENTS)
    end
  end
end
