require "json"

module ChatProviders
  class Codex < Base
    def self.provider = "codex"

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
      lock_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      CodexAuth.with_refresh_lock(user: chat.user) do
        timing.record("auth_refresh_lock", started_at: lock_started_at, mode: chat.user.codex_auth_mode)
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
    end

    private

    def invoke_with_auth(workspace_path:, prompt:, log_sink:, mcp_config:,
                         resume_session_id:, stop_requested:, process_started:, startup_timing:)
      codex_home = ChatWorkspace.agent_home_for(chat, provider)
      codex_auth = CodexAuth.new(user: chat.user, codex_home: codex_home)
      auth = startup_timing.measure("auth_prepare", mode: chat.user.codex_auth_mode) { codex_auth.prepare! }

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
      return nil unless chat.claude_session&.provider == provider
      return nil unless chat.claude_session.session_id == session_id

      chat.claude_session.transcript_jsonl
    end

    def log_startup_timing(event)
      Rails.logger.info("[codex startup] chat_id=#{chat.id} #{event}")
    end
  end
end
