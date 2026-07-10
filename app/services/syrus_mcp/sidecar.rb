require "mcp"

module SyrusMcp
  # Per-run MCP server, spawned over stdio by `claude` itself. Process
  # is short-lived: starts when claude opens it, exits when claude
  # closes its stdin (or sends SIGTERM). All it needs to know is the
  # run_id; everything else comes from the DB.
  class Sidecar
    def initialize(run_id:)
      @run_id = run_id
    end

    # Builds the MCP::Server from all registered McpToolSet plugins. Each
    # tool set that is available for this run's repository contributes its
    # tool definitions; the Sidecar creates MCP::Tool proxy classes that
    # delegate calls back through the plugin's #handle method.
    #
    # Exposed as a public method so tests can exercise tool advertisement
    # and dispatch without starting the blocking stdio transport.
    def build_server
      repository = SyrusMcp.with_database_connection { Run.find(@run_id).job.repository }

      # Server name MUST match the --mcp-config key and the binary
      # basename ("syrus-mcp-sidecar"). claude-code derives MCP tool
      # prefixes inconsistently between fresh sessions (uses config key)
      # and --resume'd sessions (uses binary basename); aligning all three
      # name sources sidesteps the underlying quirk. See
      # Steps::Base#with_mcp_config for the full story.
      MCP::Server.new(
        name: "syrus-mcp-sidecar",
        tools: plugin_tools(repository),
        server_context: { run_id: @run_id }
      )
    end

    def run
      server = build_server
      transport = MCP::Server::Transports::StdioTransport.new(server)

      # Claude sends SIGTERM when it's done. Close cleanly so the
      # while-loop in StdioTransport#open exits without an exception.
      Signal.trap("TERM") { transport.close; exit 0 }

      transport.open
    end

    private

    def plugin_tools(repository)
      Syrus::PluginRegistry.providers_for(:mcp_tool_set)
        .select { |ts| ts.available_for?(repository) }
        .flat_map { |ts| mcp_tools_for(ts) }
    end

    def mcp_tools_for(tool_set_class)
      tool_set_class.tool_definitions.map do |defn|
        MCP::Tool.define(
          name: defn[:name],
          description: defn[:description],
          input_schema: defn[:input_schema]
        ) do |server_context:, **params|
          tool_set_class.new.handle(defn[:name], params, server_context)
        end
      end
    end
  end
end
