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
    # tool definitions; built-in tools are further filtered by McpToolPolicy
    # based on the run's role (e.g. submit_adversarial_review is only present
    # for adversarial-reviewer steps). External plugin tools not declared in
    # CoreToolSet::POLICY_MANAGED_NAMES bypass role filtering.
    #
    # Exposed as a public method so tests can exercise tool advertisement
    # and dispatch without starting the blocking stdio transport.
    def build_server
      run = SyrusMcp.with_database_connection {
        Run.includes(:step, job: :repository).find(@run_id)
      }
      context = McpToolContext.from_run(run)

      # Server name MUST match the --mcp-config key and the binary
      # basename ("syrus-mcp-sidecar"). claude-code derives MCP tool
      # prefixes inconsistently between fresh sessions (uses config key)
      # and --resume'd sessions (uses binary basename); aligning all three
      # name sources sidesteps the underlying quirk. See
      # Steps::Base#with_mcp_config for the full story.
      MCP::Server.new(
        name: "syrus-mcp-sidecar",
        tools: plugin_tools(run.job.repository, context),
        server_context: { run_id: @run_id }
      )
    end

    def run
      # Kill any agent-spawned preview processes when the sidecar exits
      # (whether by SIGTERM from claude or by normal EOF on stdin).
      at_exit { SyrusMcp::AgentPreviewRegistry.kill_all }

      server = build_server
      transport = MCP::Server::Transports::StdioTransport.new(server)

      # Claude sends SIGTERM when it's done. Close cleanly so the
      # while-loop in StdioTransport#open exits without an exception.
      Signal.trap("TERM") { transport.close; exit 0 }

      transport.open
    end

    private

    def plugin_tools(repository, context)
      policy_allowed = McpToolPolicy.for(context).map(&:tool_name).to_set
      managed_names  = SyrusMcp::CoreToolSet::POLICY_MANAGED_NAMES

      Syrus::PluginRegistry.providers_for(:mcp_tool_set)
        .select { |ts| ts.available_for?(repository) }
        .flat_map { |ts| mcp_tools_for(ts) }
        .select { |tool|
          name = tool.tool_name
          # External plugin tools (not declared in CoreToolSet) always pass
          # through; built-in policy-managed tools are gated by McpToolPolicy.
          !managed_names.include?(name) || policy_allowed.include?(name)
        }
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
