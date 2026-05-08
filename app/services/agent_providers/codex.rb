module AgentProviders
  class Codex < Base
    def self.provider = "codex"

    def run(prompt:, log_sink:, max_turns: nil)
      codex_home = WorkflowWorkspace.agent_home_for(workflow, provider)
      codex_auth = CodexAuth.new(user: job.user, codex_home: codex_home)
      auth = codex_auth.prepare!

      begin
        CodexInvocation.new(
          workspace.path,
          prompt: prompt,
          api_key: auth.api_key,
          log_sink: log_sink,
          runner: RunJob.agent_runner,
          codex_home: codex_home,
          mcp_server: mcp_server,
          resume_session_id: parent_session_id,
          resume_transcript_jsonl: resume_transcript_jsonl
        ).run
      ensure
        codex_auth.persist_updated_auth_json
      end
    end

    private

    def mcp_server
      {
        command: sidecar_command,
        args: sidecar_args,
        env: sidecar_env
      }
    end

    def resume_transcript_jsonl
      return nil if parent_session_id.blank?

      ClaudeSession.joins(:run)
                   .where(session_id: parent_session_id, provider: provider, runs: { job_id: job.id })
                   .where.not(transcript_jsonl: nil)
                   .order(created_at: :desc)
                   .first&.transcript_jsonl
    end
  end
end
