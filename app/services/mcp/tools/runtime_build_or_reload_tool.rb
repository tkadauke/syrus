require "mcp"

module Mcp::Tools
  class RuntimeBuildOrReloadTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_build_or_reload"

    description <<~DESC
      Build or reload the target running inside a Runtime Session (DOC-17)
      -- e.g. restart a dev server, recompile, or hot-reload. Defaults to
      the chat's primary active session when `session_id` is omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        options: { type: "object", description: "Provider-specific build/reload options." }
      }
    )

    class << self
      def call(session_id: nil, options: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        session, error = resolve_runtime_session(chat_session, session_id)
        return error if error

        provider = provider_instance_for(session)
        result = provider.build_or_reload(session.id, normalize_options(options))
        session.update!(state: "running", last_error: nil)
        Mcp::Tools.success(result)
      rescue RuntimeSessionProviders::ConfigurationError => e
        Mcp::Tools.invalid(e.message)
      rescue StandardError => e
        session&.update!(state: "failed", last_error: "#{e.class}: #{e.message}")
        Mcp::Tools.invalid("failed to build/reload runtime session: #{e.message}")
      end
    end
  end
end
