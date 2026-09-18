module AgentProviders
  class Agy < Base
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "agy"
    def self.display_name = "Antigravity"
    def self.available?   = true

    def self.provider = "agy"

    def self.configured_for_user?(user)
      user.gemini_api_key.present?
    end

    def self.refresh_usage!(user:, force: false)
      AgyCredentialProbe.refresh_for(user: user, force: force)
    end

    def self.ignore_model_for_positive_evidence?(_model)
      true
    end

    def self.mcp_tool_name(tool_name, server_name:)
      "mcp(#{server_name}/#{tool_name})"
    end

    # Rough categorical capability metadata for a future routing-rule
    # system -- not exact pricing/token data. Mirrors the identifiers
    # AgyInvocation forwards via SYRUS_AGY_MODEL/AGY_MODEL.
    def self.available_models
      [
        Syrus::Plugin::AgentProvider::ModelInfo.new(
          id: "gemini-3-pro", display_name: "Gemini 3 Pro",
          context_window: :xlarge, cost_tier: :high
        ),
        Syrus::Plugin::AgentProvider::ModelInfo.new(
          id: "gemini-3-flash", display_name: "Gemini 3 Flash",
          context_window: :large, cost_tier: :medium
        ),
        Syrus::Plugin::AgentProvider::ModelInfo.new(
          id: "gemini-2.5-flash", display_name: "Gemini 2.5 Flash",
          context_window: :large, cost_tier: :low
        )
      ]
    end

    def self.invoke_one_shot(workspace_path:, user:, runner:, scope:, prompt:, log_sink:, timeout:, max_turns:)
      api_key = user.gemini_api_key.presence
      raise ConfigurationError, "Gemini API key is required for Antigravity" if api_key.blank?

      agy_home = File.join(WorkflowWorkspace.data_root, "agent_homes", scope, user.id.to_s, "agy")
      AgyInvocation.new(
        workspace_path,
        prompt: prompt,
        api_key: api_key,
        log_sink: log_sink,
        runner: runner,
        timeout: timeout,
        agy_home: agy_home
      ).run
    end

    def session_capture(result)
      capture = super
      return nil unless capture
      return capture if capture.transcript_jsonl.present?
      return invalid_session_capture(result) unless AgyAgent::SessionPaths.valid_session_id?(result.session_id)

      path = AgyAgent::SessionPaths.canonical_path_for(
        home: WorkflowWorkspace.agent_home_for(workflow, provider),
        cwd: workspace.path,
        session_id: result.session_id
      )
      if path && File.exist?(path)
        return SessionCapture.new(
          provider: provider,
          session_id: result.session_id,
          transcript_jsonl: File.read(path),
          missing_message: nil
        )
      end

      SessionCapture.new(
        provider: provider,
        session_id: result.session_id,
        transcript_jsonl: nil,
        missing_message: "[agent_session] no Antigravity JSONL at #{path} - session continuation won't be available for this Run"
      )
    end

    private

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, mcp:, resume_session_id:, required_mcp_tools: nil,
              model: nil, effort_level: nil, **_ignored)
      log_mcp_transport_decision!(effective_mcp_transport_decision) if mcp
      api_key = job.user.reload.gemini_api_key.presence
      raise ConfigurationError, "Gemini API key is required for Antigravity" if api_key.blank?

      on_session_id = ->(sid) { @run.update_columns(live_session_id: sid) rescue nil }

      AgyInvocation.new(
        workspace_path,
        prompt: prompt,
        api_key: api_key,
        log_sink: log_sink,
        runner: RunJob.agent_runner,
        timeout: timeout,
        agy_home: WorkflowWorkspace.agent_home_for(workflow, provider),
        resume_session_id: resume_session_id,
        resume_transcript_jsonl: resume_transcript_jsonl(resume_session_id),
        mcp_server: (mcp ? mcp_server : nil),
        required_mcp_tools: required_mcp_tools,
        model: model,
        effort_level: effort_level,
        on_session_id: on_session_id
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

    def invalid_session_capture(result)
      SessionCapture.new(
        provider: provider,
        session_id: result.session_id,
        transcript_jsonl: nil,
        missing_message: "[agent_session] invalid Antigravity session id - session continuation won't be available for this Run"
      )
    end

    def resume_transcript_jsonl(session_id)
      AgentProviders::SessionStore.transcript_for(provider: provider, session_id: session_id, job: job)
    end
  end
end
