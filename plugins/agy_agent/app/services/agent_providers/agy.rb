module AgentProviders
  class Agy < Base
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "agy"
    def self.display_name = "Antigravity"
    def self.available?   = true

    def self.provider = "agy"

    def self.mcp_tool_name(tool_name, server_name:)
      "mcp(#{server_name}/#{tool_name})"
    end

    def self.invoke_one_shot(workspace_path:, user:, runner:, scope:, prompt:, log_sink:, timeout:, max_turns:)
      agy_home = File.join(WorkflowWorkspace.data_root, "agent_homes", scope, user.id.to_s, "agy")
      AgyInvocation.new(
        workspace_path,
        prompt: prompt,
        log_sink: log_sink,
        runner: runner,
        timeout: timeout,
        agy_home: agy_home
      ).run
    end

    private

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, mcp:, resume_session_id:, required_mcp_tools: nil, **_ignored)
      log_mcp_transport_decision!(effective_mcp_transport_decision) if mcp

      AgyInvocation.new(
        workspace_path,
        prompt: prompt,
        log_sink: log_sink,
        runner: RunJob.agent_runner,
        timeout: timeout,
        agy_home: WorkflowWorkspace.agent_home_for(workflow, provider),
        resume_session_id: resume_session_id,
        mcp_server: (mcp ? mcp_server : nil),
        required_mcp_tools: required_mcp_tools
      ).run
    end

    def effective_mcp_transport_decision
      decision = mcp_transport_decision
      return decision unless decision&.persistent?

      WorkflowMcpTransportSelector::Decision.new(
        transport: :stdio,
        reason: "provider_unsupported: agy has no persistent MCP HTTP transport wiring yet",
        daemon_identity: nil
      )
    end

    def mcp_server
      {
        command: sidecar_command,
        args: sidecar_args,
        env: sidecar_env
      }
    end
  end
end
