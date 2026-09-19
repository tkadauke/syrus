module AgentProviders
  class Muse < Base
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "muse"
    def self.display_name = "Muse Code"
    def self.available? = true

    def self.provider = "muse"

    def self.configured_for_user?(user)
      user.muse_api_key.present?
    end

    def self.mcp_tool_name(tool_name, server_name:)
      normalized_server = server_name.to_s.gsub(/[^A-Za-z0-9_]/, "_")
      "mcp__#{normalized_server}__#{tool_name}"
    end

    def self.invoke_one_shot(workspace_path:, user:, runner:, scope:, prompt:, log_sink:, timeout:, max_turns:)
      MuseInvocation.new(
        workspace_path,
        prompt: prompt,
        api_key: user.muse_api_key,
        log_sink: log_sink,
        runner: runner,
        timeout: timeout,
        max_model_steps: max_turns,
        muse_home: File.join(WorkflowWorkspace.data_root, "agent_homes", scope, user.id.to_s, "muse")
      ).run
    end

    private

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, max_turns:, mcp:, resume_session_id:, required_mcp_tools: nil, **_ignored)
      log_mcp_transport_decision!(effective_mcp_transport_decision) if mcp

      MuseInvocation.new(
        workspace_path,
        prompt: prompt,
        api_key: job.user.reload.muse_api_key,
        log_sink: log_sink,
        runner: RunJob.agent_runner,
        timeout: timeout,
        session_id: resume_session_id,
        max_model_steps: max_turns,
        muse_home: WorkflowWorkspace.agent_home_for(workflow, provider),
        mcp_server: (mcp ? mcp_server : nil),
        required_mcp_tools: required_mcp_tools
      ).run
    end

    # Muse Code reads MCP servers from ~/.config/muse/settings.json. Keep that
    # home per workflow so sidecar run ids and session state never bleed across
    # jobs.
    def effective_mcp_transport_decision
      decision = mcp_transport_decision
      return decision unless decision&.persistent?

      WorkflowMcpTransportSelector::Decision.new(
        transport: :stdio,
        reason: "provider_unsupported: muse has no persistent MCP HTTP transport wiring yet",
        daemon_identity: nil
      )
    end

    def mcp_server
      {
        "syrus-mcp-sidecar" => {
          command: sidecar_command,
          args: sidecar_args,
          env: sidecar_env
        }
      }
    end
  end
end
