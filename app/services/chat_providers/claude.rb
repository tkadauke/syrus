require "fileutils"

module ChatProviders
  class Claude < Base
    SESSION_ID_PATTERN = /\A[A-Za-z0-9_-]+\z/
    PLANNING_DISALLOWED_TOOLS = %w[
      Write
      Edit
      MultiEdit
      NotebookEdit
      AskUserQuestion
    ].freeze

    # In Coding Mode the agent implements directly — Write/Edit/Bash are
    # intentionally available. Only tools with no legitimate coding use
    # remain blocked.
    CODING_DISALLOWED_TOOLS = %w[
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

    # Startup noise from a doomed `--resume`: the scary "No conversation found"
    # line, and the immediate error result whose turn count is ZERO. Scoped to
    # turns=0 so a genuine mid-turn failure (turns > 0) is never hidden.
    STALE_RESUME_NOISE = /No conversation found with session ID|subtype=error_during_execution.*turns=0\b/i

    # `claude --resume <id>` HARD-FAILS at startup when the on-disk conversation
    # is gone (worker restart, session expiry, session-file format drift) —
    # is_error with ZERO turns, before the agent runs at all ("No conversation
    # found with session ID: ..."). The turn prompt already carries a compact
    # chat-history fallback for exactly this case (see ChatTurnJob#prompt_for),
    # but a hard resume failure never reaches it. So: detect the stale-resume
    # failure and retry ONCE without --resume — a fresh session stays coherent
    # from the fallback transcript instead of the whole turn dying. Without this,
    # EVERY chat breaks after a worker restart, not just walkthroughs.
    def invoke(workspace_path:, prompt:, log_sink:, mcp_config:, resume_session_id:,
               stop_requested:, process_started:)
      ensure_claude_session_on_disk!(workspace_path: workspace_path, session_id: resume_session_id)

      result = run_invocation(
        workspace_path: workspace_path, prompt: prompt, mcp_config: mcp_config,
        resume_session_id: resume_session_id, stop_requested: stop_requested,
        process_started: process_started,
        # During the resume attempt, swallow the stale-session startup noise so a
        # clean fresh-retry doesn't strand a "No conversation found" error in the
        # thread. Healthy turns never emit these strings, so live streaming is
        # untouched; a genuine mid-turn error (turns > 0) is NOT filtered.
        log_sink: resume_session_id.present? ? filtered_log_sink(log_sink) : log_sink
      )

      if resume_session_id.present? && stale_resume_failure?(result)
        log_sink.call(
          "The previous chat session was unavailable, so Syrus is continuing from recent history.",
          kind: "system"
        )
        result = run_invocation(
          # The resume-mode prompt deliberately OMITS the full system prompt (a
          # resumed session already carries it). A fresh session doesn't — so
          # without this it would run with no role / tool / proposal-flow
          # instructions. Prepend the full chat system prompt for the fresh retry.
          workspace_path: workspace_path, prompt: prompt_with_system(prompt), mcp_config: mcp_config,
          resume_session_id: nil, stop_requested: stop_requested,
          process_started: process_started, log_sink: log_sink
        )
      end

      result
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
          normalized_messages: normalized_messages_for(transcript),
          missing_message: nil
        )
      else
        SessionCapture.new(
          provider: provider,
          session_id: result.session_id,
          transcript_jsonl: nil,
          normalized_messages: [],
          missing_message: "[chat_session] no JSONL at #{path} - session continuation won't be available for this chat"
        )
      end
    end

    private

    def run_invocation(workspace_path:, prompt:, mcp_config:, resume_session_id:,
                       stop_requested:, process_started:, log_sink:)
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
        disallowed_tools: disallowed_tools,
        model: chat.chat_model.presence,
        env: env,
        stop_requested: stop_requested,
        process_started: process_started
      ).run
    end

    # Prepend the full chat system prompt so the fresh-retry session gets the
    # role / tools / proposal-flow instructions the resume-mode prompt omits.
    def prompt_with_system(prompt)
      system = Prompts::ChatSystem.new(repository: chat.repository, chat_session: chat).to_s
      "#{system}\n\n---\n\n#{prompt}"
    end

    # A resume that died before the agent produced a single turn — the
    # signature of `claude --resume <gone-session>`. A real turn that errors
    # partway has turns > 0 and is left alone.
    def stale_resume_failure?(result)
      return false unless result

      result.is_error && result.turns.to_i.zero? &&
        result.outcome.to_s == "error_during_execution"
    end

    # Wrap the turn's log sink to drop the stale-resume startup noise while the
    # resume attempt runs, forwarding everything else live and unmodified.
    def filtered_log_sink(log_sink)
      lambda do |*args, **kwargs|
        chunk = args.first
        next if chunk.is_a?(String) && chunk.match?(STALE_RESUME_NOISE)

        log_sink.call(*args, **kwargs)
      end
    end

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
    rescue SystemCallError => e
      Rails.logger.warn("[ChatProviders::Claude] unable to rehydrate Claude session #{session_id}: #{e.class}: #{e.message}")
    end

    def disallowed_tools
      return CODING_DISALLOWED_TOOLS if Feature.coding_mode_enabled? && chat.coding?

      PLANNING_DISALLOWED_TOOLS
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
        normalized_messages: [],
        missing_message: "[chat_session] invalid Claude session id - " \
                         "session continuation won't be available for this chat"
      )
    end
  end
end
