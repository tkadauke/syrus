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

    def run
      # Build a role-specific tool list so each step kind only sees the
      # submission tools that are appropriate for it. McpToolPolicy.for(context)
      # returns the full workflow tool set filtered by the run's role:
      # - WORKFLOW_ADVERSARIAL_REVIEWER gets submit_adversarial_review, not submit_summary/test_plan.
      # - All other workflow roles get submit_summary/test_plan, not submit_adversarial_review.
      tools = SyrusMcp.with_database_connection do
        context = McpToolContext.from_run(Run.includes(:step, job: :repository).find(@run_id))
        McpToolPolicy.for(context)
      end

      # Server name MUST match the --mcp-config key and the binary
      # basename ("syrus-mcp-sidecar"). claude-code derives MCP tool
      # prefixes inconsistently between fresh sessions (uses config key)
      # and --resume'd sessions (uses binary basename); aligning all three
      # name sources sidesteps the underlying quirk. See
      # Steps::Base#with_mcp_config for the full story.
      server = MCP::Server.new(
        name: "syrus-mcp-sidecar",
        tools: tools,
        server_context: { run_id: @run_id }
      )
      transport = MCP::Server::Transports::StdioTransport.new(server)

      # Claude sends SIGTERM when it's done. Close cleanly so the
      # while-loop in StdioTransport#open exits without an exception.
      Signal.trap("TERM") { transport.close; exit 0 }

      transport.open
    end
  end
end
