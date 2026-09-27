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
      log_mcp_transport_decision!(effective_stdio_mcp_transport_decision) if mcp

      result = run_invocation(
        workspace_path: workspace_path,
        prompt: prompt,
        log_sink: log_sink,
        timeout: timeout,
        max_turns: max_turns,
        mcp: mcp,
        resume_session_id: resume_session_id,
        required_mcp_tools: required_mcp_tools
      )

      if resume_session_id.present? && context_exhausted_failure?(result)
        log_sink.call(
          "The previous Muse workflow session exhausted its context window, so Syrus is retrying this step with a fresh session.",
          kind: "system"
        )
        result = run_invocation(
          workspace_path: workspace_path,
          prompt: prompt,
          log_sink: log_sink,
          timeout: timeout,
          max_turns: max_turns,
          mcp: mcp,
          resume_session_id: nil,
          required_mcp_tools: required_mcp_tools
        )
      end

      result
    end

    def run_invocation(workspace_path:, prompt:, log_sink:, timeout:, max_turns:, mcp:, resume_session_id:,
                       required_mcp_tools:)
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

    def context_exhausted_failure?(result)
      return false unless result&.is_error

      [ result.outcome, result.final_text ].compact.join(" ").match?(
        /prompt is too long|context.*too long|maximum context|context length|context window.*(?:full|exhausted)|ran out of room in the model's context window/i
      )
    end

    def mcp_server
      {
        "syrus-mcp-sidecar" => stdio_mcp_server_config
      }
    end
  end
end
