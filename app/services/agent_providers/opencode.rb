module AgentProviders
  class Opencode < Base
    include Syrus::Plugin::AgentProvider

    def self.provider = "opencode"
    def self.display_name = "OpenCode (Ollama)"
    def self.available? = true

    private

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, mcp:, resume_session_id:, **_ignored)
      opencode_home = WorkflowWorkspace.agent_home_for(workflow, provider)

      OpencodeInvocation.new(
        workspace_path,
        prompt: prompt,
        model: job.user.opencode_model.presence || ENV.fetch("SYRUS_OPENCODE_MODEL", OpencodeInvocation::DEFAULT_OLLAMA_MODEL),
        log_sink: log_sink,
        runner: RunJob.agent_runner,
        timeout: timeout,
        opencode_home: opencode_home,
        mcp_server: (mcp ? mcp_server : nil),
        resume_session_id: resume_session_id
      ).run
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
