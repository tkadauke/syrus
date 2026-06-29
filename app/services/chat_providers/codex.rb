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
      CodexAuth.with_refresh_lock(user: chat.user) do
        invoke_with_auth(
          workspace_path: workspace_path,
          prompt: prompt,
          log_sink: log_sink,
          mcp_config: mcp_config,
          resume_session_id: resume_session_id,
          stop_requested: stop_requested,
          process_started: process_started
        )
      end
    end

    private

    def invoke_with_auth(workspace_path:, prompt:, log_sink:, mcp_config:,
                         resume_session_id:, stop_requested:, process_started:)
      codex_home = ChatWorkspace.agent_home_for(chat, provider)
      codex_auth = CodexAuth.new(user: chat.user, codex_home: codex_home)
      auth = codex_auth.prepare!

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
          process_started: process_started
        ).run
      ensure
        codex_auth.persist_updated_auth_json
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
  end
end
