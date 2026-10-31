require "mcp"

module Mcp::Tools
  class ReadPerformanceLogEventsTool < MCP::Tool
    MAX_EVENTS = 100

    tool_name "read_performance_log_events"
    description "Read capped, redacted slow requests, slow SQL, slow phases, jobs, and browser traces."
    input_schema(properties: {
      event_name: { type: "string" }, since: { type: "string" }, until: { type: "string" },
      app_revision: { type: "string" }, request_id: { type: "string" }, trace_id: { type: "string" },
      job_class: { type: "string" }, path: { type: "string" }, controller: { type: "string" },
      action: { type: "string" }, sql_fingerprint: { type: "string" },
      revision_scope: { type: "string", enum: %w[current all] },
      limit: { type: "integer" }
    })

    class << self
      include CoworkerObservabilityAuthorization

      def call(server_context:, **arguments)
        return Mcp::Tools.unauthorized("Observability access required") unless observability_authorized?(server_context)

        revision_scope = arguments.fetch(:revision_scope, "current")
        events = PerformanceLogging::Store.recent(limit: capped_limit(arguments.fetch(:limit, 50)))
        events = filter(events, arguments)
        events.select! { |event| event["app_revision"] == SyrusVersion.current } unless revision_scope == "all"
        Mcp::Tools.success(CommandRedactor.redact_value(
          current_revision: SyrusVersion.current,
          revision_scope: revision_scope == "all" ? "all" : "current",
          summaries: PerformanceLogging::Summaries.call(events),
          events: events.first(MAX_EVENTS)
        ))
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::ReadPerformanceLogEventsTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def capped_limit(value) = (Integer(value, exception: false) || 50).clamp(1, MAX_EVENTS)

      def filter(events, arguments)
        since_time = parse_time(arguments[:since])
        end_time = parse_time(arguments[:until])
        events.select do |event|
          matches?(event["event"] || event["event_name"], arguments[:event_name]) &&
            matches?(event["app_revision"], arguments[:app_revision], prefix: true) &&
            %i[request_id trace_id job_class path controller action].all? { |key| matches?(event[key.to_s], arguments[key]) } &&
            matches?(event["fingerprint"], arguments[:sql_fingerprint]) &&
            (since_time.nil? || event_time(event) >= since_time) &&
            (end_time.nil? || event_time(event) <= end_time)
        end
      end

      def matches?(value, filter, prefix: false)
        return true if filter.blank?

        prefix ? value.to_s.start_with?(filter.to_s) : value.to_s.include?(filter.to_s)
      end

      def parse_time(value)
        return if value.blank?
        return Regexp.last_match(1).to_i.minutes.ago if value.to_s.match?(/\A(\d+)m\z/)
        return Regexp.last_match(1).to_i.hours.ago if value.to_s.match?(/\A(\d+)h\z/)
        return Regexp.last_match(1).to_i.days.ago if value.to_s.match?(/\A(\d+)d\z/)

        Time.zone.parse(value.to_s)
      end

      def event_time(event) = Time.zone.parse(event["occurred_at"].to_s)
    end
  end
end
