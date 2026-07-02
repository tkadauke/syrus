require "fileutils"

module ChatProviders
  class Claude < Base
    SESSION_ID_PATTERN = /\A[A-Za-z0-9_-]+\z/
    DISALLOWED_TOOLS = %w[
      Write
      Edit
      MultiEdit
      NotebookEdit
      AskUserQuestion
    ].freeze

    def self.provider = "claude"

    def credentials_missing?
      chat.user.claude_oauth_token.blank?
    end

    def credentials_missing_message
      "Claude credentials are missing. Add a Claude OAuth token in Credentials, then send another message."
    end

    def invoke(workspace_path:, prompt:, log_sink:, mcp_config:, resume_session_id:,
               stop_requested:, process_started:)
      ensure_claude_session_on_disk!(workspace_path: workspace_path, session_id: resume_session_id)
      ClaudeInvocation.new(
        workspace_path,
        prompt: prompt,
        oauth_token: chat.user.claude_oauth_token,
        log_sink: log_sink,
        runner: runner,
        max_turns: nil,
        mcp_config: mcp_config,
        image_paths: image_paths,
        file_paths: file_paths,
        resume_session_id: resume_session_id,
        disallowed_tools: DISALLOWED_TOOLS,
        env: env,
        stop_requested: stop_requested,
        process_started: process_started
      ).run
    end

    def session_capture(result)
      capture = super
      return nil unless capture
      return capture if capture.transcript_jsonl.present?

      session_id = normalized_session_id(result.session_id)
      return missing_session_capture(result) unless session_id

      path = ClaudeSession.canonical_path_for(
        home: ENV.fetch("HOME"),
        cwd: ChatWorkspace.path_for(chat),
        session_id: session_id
      )

      if File.exist?(path)
        transcript = File.read(path)
        SessionCapture.new(
          provider: provider,
          session_id: result.session_id,
          transcript_jsonl: transcript,
          raw_provider_transcript: transcript,
          normalized_messages: normalized_messages_for(transcript),
          missing_message: nil
        )
      else
        SessionCapture.new(
          provider: provider,
          session_id: result.session_id,
          transcript_jsonl: nil,
          raw_provider_transcript: nil,
          normalized_messages: [],
          missing_message: "[chat_session] no JSONL at #{path} - session continuation won't be available for this chat"
        )
      end
    end

    private

    def ensure_claude_session_on_disk!(workspace_path:, session_id:)
      return if session_id.blank?

      path = ClaudeSession.canonical_path_for(
        home: ENV.fetch("HOME"),
        cwd: workspace_path,
        session_id: session_id
      )
      return if File.exist?(path)
      return unless chat.messages.exists?

      jsonl = ChatSessionRehydrator::Claude.new(chat, session_id: session_id, cwd: workspace_path.to_s).call
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, jsonl)
    end

    def normalized_session_id(session_id)
      normalized = session_id.to_s
      return unless normalized.match?(SESSION_ID_PATTERN)

      normalized
    end

    def missing_session_capture(result)
      SessionCapture.new(
        provider: provider,
        session_id: result.session_id,
        transcript_jsonl: nil,
        raw_provider_transcript: nil,
        normalized_messages: [],
        missing_message: "[chat_session] invalid Claude session id - " \
                         "session continuation won't be available for this chat"
      )
    end
  end
end
