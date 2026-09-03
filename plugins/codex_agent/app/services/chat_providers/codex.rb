require "json"

module ChatProviders
  class Codex < Base
    include Syrus::Plugin::ChatProvider

    def self.provider_key = "codex"
    def self.display_name = "Codex"
    def self.available? = true

    def self.provider = provider_key
    def self.configured_model = CodexInvocation.configured_model

    def self.invoke_event_evaluator(chat_session:, workspace_path:, prompt:, session_id:, transcript_jsonl:, mcp_config:, timeout:, max_turns:, runner:)
      codex_home = ChatWorkspace.agent_home_for(chat_session, "codex")
      codex_auth = CodexAuth.new(user: chat_session.user, codex_home: codex_home)
      auth = CodexAuth.with_refresh_lock(user: chat_session.user) { codex_auth.prepare! }
      CodexInvocation.new(
        workspace_path,
        prompt: prompt,
        api_key: auth.api_key,
        log_sink: ->(*) { },
        runner: runner,
        timeout: timeout,
        codex_home: codex_home,
        mcp_servers: mcp_servers_for(mcp_config),
        resume_session_id: session_id,
        resume_transcript_jsonl: transcript_jsonl
      ).run
    ensure
      codex_auth&.persist_updated_auth_json
      CodexUsageProbe.refresh_for(user: chat_session.user) if chat_session.user.codex_auth_mode == "chatgpt_login"
    end

    def credentials_missing?
      !chat.user.chat_provider_configured?(provider)
    end

    def credentials_missing_message
      "Codex credentials are missing. Add Codex credentials in Credentials, then send another message."
    end

    def invoke(workspace_path:, prompt:, log_sink:, mcp_config:, resume_session_id:,
               stop_requested:, process_started:)
      timing = CodexInvocation::StartupTiming.new(
        source: "codex_chat",
        sink: method(:log_startup_timing)
      )
      invoke_with_auth(
        workspace_path: workspace_path,
        prompt: prompt,
        log_sink: log_sink,
        mcp_config: mcp_config,
        resume_session_id: resume_session_id,
        stop_requested: stop_requested,
        process_started: process_started,
        startup_timing: timing
      )
    end

    private

    def self.mcp_servers_for(path)
      raw = JSON.parse(File.read(path))
      raw.fetch("mcpServers").transform_values do |server|
        {
          command: server.fetch("command"),
          args: Array(server["args"]),
          env: server.fetch("env", {}),
          required: server["alwaysLoad"] != false
        }
      end
    end

    def invoke_with_auth(workspace_path:, prompt:, log_sink:, mcp_config:,
                         resume_session_id:, stop_requested:, process_started:, startup_timing:)
      codex_home = ChatWorkspace.agent_home_for(chat, provider)
      codex_auth = CodexAuth.new(user: chat.user, codex_home: codex_home)
      lock_started_at = startup_timing.now
      auth = CodexAuth.with_refresh_lock(user: chat.user) do
        startup_timing.record("auth_refresh_lock", started_at: lock_started_at, mode: chat.user.codex_auth_mode)
        startup_timing.measure("auth_prepare", mode: chat.user.codex_auth_mode) { codex_auth.prepare! }
      end

      begin
        CodexInvocation.new(
          workspace_path,
          prompt: prompt,
          api_key: auth.api_key,
          log_sink: log_sink,
          runner: runner,
          codex_home: codex_home,
          mcp_servers: mcp_servers_for(mcp_config),
          resume_session_id: resume_session_id,
          resume_transcript_jsonl: resume_transcript_jsonl(resume_session_id),
          stop_requested: stop_requested,
          process_started: process_started,
          startup_timing: startup_timing
        ).run
      ensure
        startup_timing.measure("auth_persist", mode: chat.user.codex_auth_mode) do
          codex_auth.persist_updated_auth_json
        end
        startup_timing.measure("usage_probe", mode: chat.user.codex_auth_mode) do
          CodexUsageProbe.refresh_for(user: chat.user) if chat.user.codex_auth_mode == "chatgpt_login"
        end
      end
    end

    def mcp_servers_for(path)
      raw = JSON.parse(File.read(path))
      raw.fetch("mcpServers").transform_values do |server|
        {
          command: server.fetch("command"),
          args: Array(server["args"]),
          env: server.fetch("env", {}),
          required: server["alwaysLoad"] != false
        }
      end
    end

    def resume_transcript_jsonl(session_id)
      return nil if session_id.blank?

      if ChatContextCompactor.enabled_for?(chat)
        return ChatSessionRehydrator::Codex.new(chat, session_id: session_id).call
      end

      # Fast path: provider matches and transcript is cached
      session = chat.provider_session
      if session&.provider == provider && session.session_id == session_id && session.transcript_jsonl.present?
        return session.transcript_jsonl
      end

      # Rehydrate from ChatMessage rows (cross-provider switch or missing cache)
      return nil unless chat.messages.exists?

      ChatSessionRehydrator::Codex.new(chat, session_id: session_id).call
    end

    def log_startup_timing(event)
      Rails.logger.info("[codex startup] chat_id=#{chat.id} #{event}")
    end
  end
end
