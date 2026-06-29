module AgentProviders
  class OpenCode < Base
    def self.provider = "opencode"

    private

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, mcp:, resume_session_id:, **_ignored)
      raise ConfigurationError, "OpenCode is not configured" unless job.user.opencode_configured?

      OpenCodeInvocation.new(
        workspace_path,
        prompt: prompt,
        backend_config: backend_config,
        log_sink: log_sink,
        runner: RunJob.agent_runner,
        timeout: timeout,
        opencode_home: WorkflowWorkspace.agent_home_for(workflow, provider),
        mcp_server: (mcp ? mcp_server : nil),
        resume_session_id: resume_session_id,
        resume_transcript_jsonl: resume_transcript_jsonl(resume_session_id)
      ).run
    end

    def backend_config
      OpenCodeInvocation::BackendConfig.new(
        backend: job.user.opencode_backend,
        model: job.user.opencode_model,
        api_key: job.user.opencode_api_key,
        endpoint_url: job.user.opencode_endpoint_url
      )
    end

    def mcp_server
      {
        command: sidecar_command,
        args: sidecar_args,
        env: sidecar_env
      }
    end

    def resume_transcript_jsonl(session_id)
      AgentProviders::SessionStore.transcript_for(provider: provider, session_id: session_id, job: job)
    end
  end
end
