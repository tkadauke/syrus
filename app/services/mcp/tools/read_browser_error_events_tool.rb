require_relative "read_observability_event_tools"

module Mcp::Tools
  class ReadBrowserErrorEventsTool < MCP::Tool
    tool_name "read_browser_error_events"
    description "Read capped, redacted browser error events using the admin event-log filters."
    input_schema(properties: {
      query: { type: "string" }, since: { type: "string" }, until: { type: "string" },
      id: { type: "integer" }, fingerprint: { type: "string" }, path: { type: "string" },
      revision_scope: { type: "string", enum: %w[current all] }, limit: { type: "integer" }
    })

    class << self
      include CoworkerObservabilityAuthorization
      include ReadObservabilityEventTools

      def call(server_context:, **filters)
        read_events(server_context: server_context, payload_class: Admin::BrowserErrorEventsPayload, **filters)
      end
    end
  end
end
