module AgentProviders
  class Codex < Base
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "codex"
    def self.display_name = "Codex"
    def self.available?   = true

    def self.provider = "codex"

    def self.refresh_stale_usage!(user:, now: Time.current)
      return unless user.codex_auth_mode == "chatgpt_login"
      return unless CodexUsageProbe.stale?(user, now: now)

      CodexUsageProbe.refresh_for(user: user)
    end

    def self.invoke_one_shot(workspace_path:, user:, runner:, scope:, prompt:, log_sink:, timeout:, max_turns:)
      codex_home = File.join(WorkflowWorkspace.data_root, "agent_homes", scope, user.id.to_s, "codex")
      codex_auth = CodexAuth.new(user: user, codex_home: codex_home)
      auth = CodexAuth.with_refresh_lock(user: user) { codex_auth.prepare! }
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
        CodexUsageProbe.refresh_for(user: user) if user.codex_auth_mode == "chatgpt_login"
      end
    end

    private

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, mcp:, resume_session_id:, **_ignored)
      log_mcp_transport_decision!(effective_mcp_transport_decision) if mcp

      invoke_with_auth(
        workspace_path: workspace_path,
        prompt: prompt,
        log_sink: log_sink,
        timeout: timeout,
        mcp: mcp,
        resume_session_id: resume_session_id
      )
    end

    # Codex's MCP config (config.toml, see #mcp_server / #codex_config_toml)
    # only models stdio servers -- there's no verified remote/HTTP MCP
    # transport wiring for the codex CLI in this codebase, so Codex always
    # stays on the existing stdio sidecar regardless of what
    # WorkflowMcpTransportSelector would otherwise pick. The selector still
    # runs (so its decision -- and, when it would have gone persistent, an
    # explicit provider_unsupported fallback reason -- lands in the same
    # run/job diagnostics as Claude) rather than being skipped outright.
    def effective_mcp_transport_decision
      decision = mcp_transport_decision
      return decision unless decision&.persistent?

      WorkflowMcpTransportSelector::Decision.new(
        transport: :stdio,
        reason: "provider_unsupported: codex has no persistent MCP HTTP transport wiring yet",
        daemon_identity: nil
      )
    end

    def invoke_with_auth(workspace_path:, prompt:, log_sink:, timeout:, mcp:, resume_session_id:)
      codex_home = WorkflowWorkspace.agent_home_for(workflow, provider)
      codex_auth = CodexAuth.new(user: job.user, codex_home: codex_home)
      auth = CodexAuth.with_refresh_lock(user: job.user) { codex_auth.prepare! }

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
        CodexUsageProbe.refresh_for(user: job.user) if job.user.codex_auth_mode == "chatgpt_login"
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
