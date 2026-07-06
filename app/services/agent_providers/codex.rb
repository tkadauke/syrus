module AgentProviders
  class Codex < Base
    def self.provider = "codex"

    def self.invoke_one_shot(workspace_path:, user:, runner:, scope:, prompt:, log_sink:, timeout:, max_turns:)
      codex_home = File.join(WorkflowWorkspace.data_root, "agent_homes", scope, user.id.to_s, "codex")
      CodexAuth.with_refresh_lock(user: user) do
        codex_auth = CodexAuth.new(user: user, codex_home: codex_home)
        auth = codex_auth.prepare!
        begin
          CodexInvocation.new(
            workspace_path,
            prompt: prompt,
            api_key: auth.api_key,
            log_sink: log_sink,
            runner: runner,
            timeout: timeout,
            codex_home: codex_home
          ).run
        ensure
          codex_auth.persist_updated_auth_json
        end
      end
    end

    private

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, mcp:, resume_session_id:, **_ignored)
      CodexAuth.with_refresh_lock(user: job.user) do
        invoke_with_auth(
          workspace_path: workspace_path,
          prompt: prompt,
          log_sink: log_sink,
          timeout: timeout,
          mcp: mcp,
          resume_session_id: resume_session_id
        )
      end
    end

    def invoke_with_auth(workspace_path:, prompt:, log_sink:, timeout:, mcp:, resume_session_id:)
      codex_home = WorkflowWorkspace.agent_home_for(workflow, provider)
      codex_auth = CodexAuth.new(user: job.user, codex_home: codex_home)
      auth = codex_auth.prepare!

      begin
        CodexInvocation.new(
          workspace_path,
          prompt: prompt,
          api_key: auth.api_key,
          log_sink: log_sink,
          runner: RunJob.agent_runner,
          timeout: timeout,
          codex_home: codex_home,
          mcp_server: (mcp ? mcp_server : nil),
          resume_session_id: resume_session_id,
          resume_transcript_jsonl: resume_transcript_jsonl(resume_session_id)
        ).run
      ensure
        codex_auth.persist_updated_auth_json
      end
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
