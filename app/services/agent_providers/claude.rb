require "tempfile"

module AgentProviders
  class Claude < Base
    SESSION_ID_PATTERN = /\A[A-Za-z0-9_-]+\z/

    def self.provider = "claude"

    def session_capture(result)
      capture = super
      return nil unless capture
      return capture if capture.transcript_jsonl.present?
      session_id = normalized_session_id(result.session_id)
      return missing_session_capture(result) unless session_id

      path = ClaudeSession.canonical_path_for(
        home: ENV.fetch("HOME"),
        cwd: workspace.path,
        session_id: session_id
      )

      if File.exist?(path)
        SessionCapture.new(
          provider: provider,
          session_id: result.session_id,
          transcript_jsonl: File.read(path),
          missing_message: nil
        )
      else
        SessionCapture.new(
          provider: provider,
          session_id: result.session_id,
          transcript_jsonl: nil,
          missing_message: "[agent_session] no JSONL at #{path} - Resume won't be available for this Run"
        )
      end
    end

    private

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
        missing_message: "[agent_session] invalid Claude session id - Resume won't be available for this Run"
      )
    end

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, max_turns:, mcp:, resume_session_id:)
      if mcp
        with_mcp_config do |mcp_config_path|
          invoke_claude(workspace_path: workspace_path,
                        prompt: prompt,
                        log_sink: log_sink,
                        timeout: timeout,
                        max_turns: max_turns,
                        mcp_config: mcp_config_path,
                        resume_session_id: resume_session_id)
        end
      else
        invoke_claude(workspace_path: workspace_path,
                      prompt: prompt,
                      log_sink: log_sink,
                      timeout: timeout,
                      max_turns: max_turns,
                      mcp_config: nil,
                      resume_session_id: resume_session_id)
      end
    end

    def invoke_claude(workspace_path:, prompt:, log_sink:, timeout:, max_turns:, mcp_config:, resume_session_id:)
      ClaudeInvocation.new(
        workspace_path,
        prompt: prompt,
        oauth_token: job.user.claude_oauth_token,
        log_sink: log_sink,
        runner: RunJob.agent_runner,
        timeout: timeout,
        max_turns: max_turns,
        mcp_config: mcp_config,
        resume_session_id: resume_session_id
      ).run
    end

    # Per-Run mcp.json tempfile so claude knows how to reach our
    # sidecar. `alwaysLoad: true` (claude-code v2.1.121+) skips
    # tool-search deferral and keeps `mcp__syrus__submit_summary`
    # in the agent's active tool list at all times, including on
    # `--resume`d sessions, where claude was otherwise routing MCP
    # tools through the deferred catalog and the resumed agent
    # couldn't find them. Server key MUST match the binary basename
    # (`syrus-mcp-sidecar`) because claude-code derives resumed MCP
    # tool prefixes from the binary basename.
    def with_mcp_config
      Tempfile.create([ "syrus-mcp-#{@run.id}-", ".json" ]) do |f|
        f.write({
          mcpServers: {
            "syrus-mcp-sidecar" => {
              type: "stdio",
              command: sidecar_command,
              args: sidecar_args,
              env: sidecar_env,
              alwaysLoad: true
            }
          }
        }.to_json)
        f.flush
        yield f.path
      end
    end
  end
end
