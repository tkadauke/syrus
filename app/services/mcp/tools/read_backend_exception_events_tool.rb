require_relative "read_observability_event_tools"

module Mcp::Tools
  class ReadBackendExceptionEventsTool < MCP::Tool
    tool_name "read_backend_exception_events"
    description "Read capped, redacted backend exception events using the admin event-log filters."
    input_schema(properties: {
      query: { type: "string" }, since: { type: "string" }, until: { type: "string" },
      fingerprint: { type: "string" }, source: { type: "string" }, exception_class: { type: "string" },
      path: { type: "string" }, revision_scope: { type: "string", enum: %w[current all] }, limit: { type: "integer" }
    })

    class << self
      include CoworkerObservabilityAuthorization
      include ReadObservabilityEventTools

      def call(server_context:, **filters)
        read_events(server_context: server_context, payload_class: Admin::BackendExceptionEventsPayload, **filters)
      end
    end
  end
end
