require "mcp"

module SyrusMcp
  # Per-run MCP server, spawned over stdio by `claude` itself. Process
  # is short-lived: starts when claude opens it, exits when claude
  # closes its stdin (or sends SIGTERM). All it needs to know is the
  # run_id; everything else comes from the DB.
  class Sidecar
    def initialize(run_id:)
      @run_id = run_id
      # Validate the id at boot, but do not keep an ActiveRecord model
      # instance in the long-lived MCP process. Agent turns can run long
      # enough for the sidecar's DB connection to go idle before the tool
      # call arrives; tools re-resolve the Run after verifying the
      # connection.
      SyrusMcp.run_from_context(run_id: @run_id)
    end

    def run
      # Server name MUST match the --mcp-config key and the binary
      # basename ("syrus-mcp-sidecar"). claude-code derives MCP tool
      # prefixes inconsistently between fresh sessions (uses config key)
      # and --resume'd sessions (uses binary basename); aligning all three
      # name sources sidesteps the underlying quirk. See
      # Steps::Base#with_mcp_config for the full story.
      server = MCP::Server.new(
        name: "syrus-mcp-sidecar",
        tools: [ SubmitSummaryTool, AskOperatorTool ],
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
