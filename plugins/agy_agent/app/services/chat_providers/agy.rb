require "json"

module ChatProviders
  class Agy < Base
    include Syrus::Plugin::ChatProvider

    def self.provider_key = "agy"
    def self.display_name = "Antigravity"
    def self.available? = true

    def self.provider = provider_key
    def self.configured_model = AgyInvocation.configured_model

    def self.invoke_event_evaluator(chat_session:, workspace_path:, prompt:, session_id:, transcript_jsonl:, mcp_config:, timeout:, max_turns:, runner:)
      api_key = chat_session.user.gemini_api_key.presence
      raise ConfigurationError, "Gemini API key is required for Antigravity" if api_key.blank?

      AgyInvocation.new(
        workspace_path,
        prompt: prompt,
        api_key: api_key,
        log_sink: ->(*) { },
        runner: runner,
        timeout: timeout,
        agy_home: ChatWorkspace.agent_home_for(chat_session, "agy"),
        resume_session_id: session_id,
        resume_transcript_jsonl: transcript_jsonl,
        mcp_servers: mcp_servers_for(mcp_config),
        model: chat_session.chat_model.presence,
        effort_level: chat_session.chat_effort
      ).run
    end

    def credentials_missing?
      chat.user.gemini_api_key.blank?
    end

    def credentials_missing_message
      "Antigravity credentials are missing. Add a Gemini API key in Credentials, then send another message."
    end

    def invoke(workspace_path:, prompt:, log_sink:, mcp_config:, resume_session_id:,
               stop_requested:, process_started:)
      api_key = chat.user.reload.gemini_api_key.presence
      raise ConfigurationError, "Gemini API key is required for Antigravity" if api_key.blank?

      AgyInvocation.new(
        workspace_path,
        prompt: prompt,
        api_key: api_key,
        log_sink: log_sink,
        runner: runner,
        agy_home: ChatWorkspace.agent_home_for(chat, provider),
        resume_session_id: resume_session_id,
        resume_transcript_jsonl: resume_transcript_jsonl(resume_session_id),
        mcp_servers: mcp_servers_for(mcp_config),
        model: chat.chat_model.presence,
        effort_level: chat.chat_effort,
        stop_requested: stop_requested,
        process_started: process_started
      ).run
    end

    def session_capture(result)
      capture = super
      return nil unless capture
      return capture if capture.transcript_jsonl.present?
      return invalid_session_capture(result) unless AgyAgent::SessionPaths.valid_session_id?(result.session_id)

      path = AgyAgent::SessionPaths.transcript_path_for(
        home: ChatWorkspace.agent_home_for(chat, provider),
        cwd: ChatWorkspace.path_for(chat),
        session_id: result.session_id
      )

      if path && File.exist?(path)
        transcript = File.read(path)
        return SessionCapture.new(
          provider: provider,
          session_id: result.session_id,
          transcript_jsonl: transcript,
          normalized_messages: normalized_messages_for(transcript),
          missing_message: nil
        )
      end

      SessionCapture.new(
        provider: provider,
        session_id: result.session_id,
        transcript_jsonl: nil,
        normalized_messages: [],
        missing_message: "[chat_session] no Antigravity JSONL at #{path} - session continuation won't be available for this chat"
      )
    end

    private

    def self.mcp_servers_for(path)
      raw = JSON.parse(File.read(path))
      raw.fetch("mcpServers").to_h.transform_values do |server|
        next unless server.fetch("type", "stdio") == "stdio"

        {
          command: server.fetch("command"),
          args: Array(server["args"]),
          env: server.fetch("env", {}),
          required: server["alwaysLoad"] != false
        }
      end.compact
    end

    def mcp_servers_for(path)
      self.class.mcp_servers_for(path)
    end

    def resume_transcript_jsonl(session_id)
      return nil if session_id.blank?

      if ChatContextCompactor.enabled_for?(chat)
        return ChatSessionRehydrator::Agy.new(chat, session_id: session_id).call
      end

      session = chat.provider_session
      if session&.provider == provider && session.session_id == session_id && session.transcript_jsonl.present?
        return session.transcript_jsonl
      end

      return nil unless chat.messages.exists?

      ChatSessionRehydrator::Agy.new(chat, session_id: session_id).call
    end

    def invalid_session_capture(result)
      SessionCapture.new(
        provider: provider,
        session_id: result.session_id,
        transcript_jsonl: nil,
        normalized_messages: [],
        missing_message: "[chat_session] invalid Antigravity session id - session continuation won't be available for this chat"
      )
    end
  end
end
