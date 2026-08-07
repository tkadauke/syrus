require "mcp"

module Mcp::Tools
  class ReadPerformanceDiagnosticsTool < MCP::Tool
    tool_name "read_performance_diagnostics"

    DESCRIPTION = <<~DESC
      Read bounded, sanitized Syrus performance diagnostics for the current app
      revision or all retained revisions. Only available to workflow agents
      working on tkadauke/syrus or a registered fork of that repository.
    DESC

    description DESCRIPTION

    input_schema(
      properties: {
        limit: {
          type: "integer",
          description: "Maximum recent events to inspect, capped by the performance diagnostics store. Defaults to 100."
        },
        revision_scope: {
          type: "string",
          enum: [ "current", "all" ],
          description: "Use current to match the running app revision, or all to include retained events from every revision."
        },
        include_events: {
          type: "boolean",
          description: "When true, include bounded sanitized raw recent events. Defaults to false."
        }
      }
    )

    class << self
      def call(server_context:, limit: Admin::PerformancePayload::DEFAULT_LIMIT, revision_scope: "current", include_events: false)
        context = McpToolContext.from_server_context(server_context)
        return Mcp::Tools.not_authorized unless context.role == AgentRole::WORKFLOW_IMPLEMENT
        return Mcp::Tools.invalid("performance diagnostics are only available for Syrus repositories") unless McpToolPolicy.syrus_repository?(context.repository)

        payload = PerformanceLogging.suppress do
          Admin::PerformancePayload.new(params: { limit: limit, revision_scope: revision_scope }).as_json
        end
        payload = sanitized_payload(payload, include_events: include_events)
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ReadPerformanceDiagnosticsTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def sanitized_payload(payload, include_events:)
        {
          enabled: payload[:enabled],
          current_revision: payload[:current_revision],
          revision_scope: payload[:revision_scope],
          thresholds: payload[:thresholds],
          storage: payload[:storage],
          summaries: sanitized_summaries(payload[:summaries])
        }.tap do |result|
          result[:events] = Array(payload[:events]).map { |event| sanitized_event(event) } if include_events
        end
      end

      def sanitized_summaries(summaries)
        summaries = summaries.to_h
        {
          slow_requests: Array(summaries[:slow_requests]).map { |row| sanitized_slow_request(row) },
          slow_phases: Array(summaries[:slow_phases]).map { |row| sanitized_slow_phase(row) },
          sql_fingerprints: Array(summaries[:sql_fingerprints]).map { |row| sanitized_sql_fingerprint(row) }
        }
      end

      def sanitized_slow_request(row)
        row.merge(path: scrub_path(row[:path]))
      end

      def sanitized_slow_phase(row)
        row.merge(recent_metadata: scrub_metadata(row[:recent_metadata]))
      end

      def sanitized_sql_fingerprint(row)
        row.except(:sample_sql).merge(fingerprint: scrub_text(row[:fingerprint], 1_000))
      end

      def sanitized_event(event)
        {
          "event" => event["event"],
          "occurred_at" => event["occurred_at"],
          "app_revision" => event["app_revision"],
          "pid" => event["pid"],
          "duration_ms" => event["duration_ms"],
          "method" => event["method"],
          "path" => scrub_path(event["path"]),
          "controller" => event["controller"],
          "action" => event["action"],
          "format" => event["format"],
          "status" => event["status"],
          "view_runtime_ms" => event["view_runtime_ms"],
          "db_runtime_ms" => event["db_runtime_ms"],
          "sql_count" => event["sql_count"],
          "sql_duration_ms" => event["sql_duration_ms"],
          "slow_sql_count" => event["slow_sql_count"],
          "phase" => event["phase"],
          "metadata" => scrub_metadata(event["metadata"]),
          "name" => scrub_text(event["name"], 200),
          "fingerprint" => scrub_text(event["fingerprint"], 1_000),
          "top_sql_fingerprints" => sanitized_top_sql_fingerprints(event["top_sql_fingerprints"])
        }.compact
      end

      def sanitized_top_sql_fingerprints(entries)
        Array(entries).map do |entry|
          entry.except("sample_sql").merge("fingerprint" => scrub_text(entry["fingerprint"], 1_000))
        end
      end

      def scrub_metadata(metadata)
        metadata.to_h.to_h do |key, value|
          [ scrub_text(key, 100), scrub_text(value, 500) ]
        end
      end

      def scrub_path(path)
        path = scrub_text(path, 500)&.split("?")&.first
        return nil if path.nil?

        previous_segment = nil
        path.split("/", -1).map do |segment|
          redacted = sensitive_path_segment?(segment, previous_segment) ? "[REDACTED]" : segment
          previous_segment = segment
          redacted
        end.join("/")
      end

      def sensitive_path_segment?(segment, previous_segment)
        return false if segment.blank?
        return true if previous_segment.to_s.match?(/\A(?:authorization|password|passwd|secret|token|api[_-]?key)\z/i)

        segment.match?(/\A(?:authorization|password|passwd|secret|token|api[_-]?key)[=:_-].+/i)
      end

      def scrub_text(value, limit)
        return nil if value.nil?

        value.to_s
          .gsub(/(authorization|password|passwd|secret|token|api[_-]?key)=([^&\s]+)/i, "\\1=[REDACTED]")
          .safe_byteslice(0, limit)
      end
    end
  end
end
