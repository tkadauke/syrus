require "tempfile"

module AgentProviders
  class Claude < Base
    include Syrus::Plugin::AgentProvider

    SESSION_ID_PATTERN = /\A[A-Za-z0-9_-]+\z/

    def self.provider_key = "claude"
    def self.display_name = "Claude Code"
    def self.available?   = true

    def self.provider = "claude"

    def self.mcp_tool_name(tool_name, server_name:)
      "mcp__#{server_name}__#{tool_name}"
    end

    def self.evidence_reset_at(evidence)
      snapshot = evidence&.details&.dig("snapshot") || {}
      minutes = [
        snapshot["session_reset_minutes"],
        snapshot["weekly_reset_minutes"]
      ].compact.min
      return if minutes.blank?

      evidence.observed_at + Float(minutes).minutes + ProviderQuotaReset::RETRY_BUFFER
    rescue ArgumentError, TypeError
      nil
    end

    def self.usage_windows(snapshot, observed_at:, now:)
      [
        [ "five_hour", "5h", snapshot["session_pct"], snapshot["session_reset_minutes"] ],
        [ "weekly", "weekly", snapshot["weekly_pct"], snapshot["weekly_reset_minutes"] ]
      ].each_with_object({}) do |(key, label, used_percent, reset_minutes), memo|
        next if used_percent.blank?

        memo[key] = {
          label: label,
          remaining_percent: (100.0 - used_percent.to_f).clamp(0.0, 100.0).round(1),
          used_percent: used_percent,
          reset_at: reset_time_from_minutes(reset_minutes, observed_at: observed_at, now: now)
        }.compact
      end
    end

    def self.reset_time_from_minutes(minutes, observed_at:, now:)
      return if minutes.blank?

      ((observed_at || now) + Float(minutes).minutes).iso8601
    rescue ArgumentError, TypeError
      nil
    end

    def self.refresh_stale_usage!(user:, now: Time.current)
      return unless user.claude_oauth_token.present?
      return unless ClaudeUsageProbe.stale?(user, now: now)

      ClaudeUsageProbe.refresh_for(user: user)
    end

    def self.refresh_usage!(user:, force: false)
      return unless user.claude_oauth_token.present?

      ClaudeUsageProbe.refresh_for(user: user, force: force)
    end

    def session_capture(result)
      capture = super
      return nil unless capture
      return capture if capture.transcript_jsonl.present?
      session_id = normalized_session_id(result.session_id)
      return missing_session_capture(result) unless session_id

      path = ProviderSession.canonical_path_for(
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
          missing_message: "[agent_session] no JSONL at #{path} - session continuation won't be available for this Run"
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
        missing_message: "[agent_session] invalid Claude session id - session continuation won't be available for this Run"
      )
    end

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, max_turns:, mcp:, resume_session_id:, required_mcp_tools: nil, disallowed_tools: nil)
      on_session_id = ->(sid) { @run.update_columns(live_session_id: sid) rescue nil }
      if mcp
        decision = mcp_transport_decision
        log_mcp_transport_decision!(decision) if decision

        with_mcp_config(decision) do |mcp_config_path|
          invoke_claude(workspace_path: workspace_path,
                        prompt: prompt,
                        log_sink: log_sink,
                        timeout: timeout,
                        max_turns: max_turns,
                        mcp_config: mcp_config_path,
                        resume_session_id: resume_session_id,
                        required_mcp_tools: required_mcp_tools,
                        disallowed_tools: disallowed_tools,
                        on_session_id: on_session_id)
        end
      else
        invoke_claude(workspace_path: workspace_path,
                      prompt: prompt,
                      log_sink: log_sink,
                      timeout: timeout,
                      max_turns: max_turns,
                      mcp_config: nil,
                      resume_session_id: resume_session_id,
                      required_mcp_tools: required_mcp_tools,
                      disallowed_tools: disallowed_tools,
                      on_session_id: on_session_id)
      end
    end

    def self.invoke_one_shot(workspace_path:, user:, runner:, scope:, prompt:, log_sink:, timeout:, max_turns:)
      ClaudeInvocation.new(
        workspace_path,
        prompt: prompt,
        oauth_token: user.claude_oauth_token,
        log_sink: log_sink,
        runner: runner,
        timeout: timeout,
        max_turns: max_turns
      ).run
    ensure
      ClaudeUsageProbe.refresh_for(user: user) if user.claude_oauth_token.present?
    end

    def invoke_claude(workspace_path:, prompt:, log_sink:, timeout:, max_turns:, mcp_config:, resume_session_id:, required_mcp_tools: nil, disallowed_tools: nil, on_session_id: ->(_) { })
      ClaudeInvocation.new(
        workspace_path,
        prompt: prompt,
        oauth_token: job.user.claude_oauth_token,
        log_sink: log_sink,
        runner: RunJob.agent_runner,
        timeout: timeout,
        max_turns: max_turns,
        mcp_config: mcp_config,
        resume_session_id: resume_session_id,
        required_mcp_tools: required_mcp_tools,
        disallowed_tools: disallowed_tools,
        on_session_id: on_session_id
      ).run
    ensure
      ClaudeUsageProbe.refresh_for(user: job.user) if job.user.claude_oauth_token.present?
    end

    # Per-Run mcp.json tempfile so claude knows how to reach our
    # sidecar. `alwaysLoad: true` (claude-code v2.1.121+) skips
    # tool-search deferral and keeps `mcp__syrus__submit_summary`
    # in the agent's active tool list at all times, including on
    # `--resume`d sessions, where claude was otherwise routing MCP
    # tools through the deferred catalog and the resumed agent
    # couldn't find them. Server key MUST match the binary basename
    # (`syrus-mcp-sidecar`) because claude-code derives resumed MCP
    # tool prefixes from the binary basename -- kept as the config key
    # for the persistent/http entry too, for the same reason (see
    # ClaudeInvocation#required_mcp_tools_update, which looks up this
    # exact name in claude's init event regardless of transport).
    def with_mcp_config(decision = nil)
      if decision&.persistent?
        with_persistent_mcp_config(decision) { |path| yield path }
      else
        with_stdio_mcp_config { |path| yield path }
      end
    end

    def with_stdio_mcp_config
      Tempfile.create([ "syrus-mcp-#{@run.id}-", ".json" ]) do |f|
        env = sidecar_env
        f.write({
          mcpServers: {
            "syrus-mcp-sidecar" => {
              type: "stdio",
              command: sidecar_command,
              args: sidecar_args,
              env: env,
              alwaysLoad: true
            }
          }
        }.to_json)
        f.flush
        log_mcp_config!(path: f.path, env: env)
        yield f.path
      end
    end

    # Points claude at PersistentMcpDaemon's HTTP transport instead of
    # spawning a stdio subprocess. The signed McpInvocationContext token
    # travels as a header (not `_meta` -- claude builds the JSON-RPC body
    # itself, so there's no config surface to set `_meta` directly); the
    # daemon bridges the header into `_meta` on its side (see
    # PersistentMcpDaemon#inject_invocation_context).
    def with_persistent_mcp_config(decision)
      Tempfile.create([ "syrus-mcp-#{@run.id}-", ".json" ]) do |f|
        url = persistent_mcp_url
        token = mint_invocation_context_token(decision)
        f.write({
          mcpServers: {
            "syrus-mcp-sidecar" => {
              type: "http",
              url: url,
              headers: { PersistentMcpDaemon::INVOCATION_CONTEXT_HEADER => token },
              alwaysLoad: true
            }
          }
        }.to_json)
        f.flush
        log_persistent_mcp_config!(path: f.path, url: url)
        yield f.path
      end
    end

    def persistent_mcp_url
      "http://#{PersistentMcpDaemon.host}:#{PersistentMcpDaemon.port}#{PersistentMcpDaemon::MCP_PATH}"
    end

    def log_mcp_config!(path:, env:)
      JobLog.append!(
        run: @run,
        kind: "system",
        chunk: "[mcp_config] server=syrus-mcp-sidecar command=#{sidecar_command} args=#{sidecar_args.join(' ')} alwaysLoad=true path=#{path} stderr=#{McpSidecarLog.path_for(@run.id)} env_keys=#{env.keys.sort.join(',')}"
      )
    rescue StandardError => e
      Rails.logger.warn("[AgentProviders::Claude] failed to log MCP config for Run ##{@run.id}: #{e.class}: #{e.message}")
    end

    def log_persistent_mcp_config!(path:, url:)
      JobLog.append!(
        run: @run,
        kind: "system",
        chunk: "[mcp_config] server=syrus-mcp-sidecar transport=persistent url=#{url} alwaysLoad=true path=#{path}"
      )
    rescue StandardError => e
      Rails.logger.warn("[AgentProviders::Claude] failed to log persistent MCP config for Run ##{@run.id}: #{e.class}: #{e.message}")
    end
  end
end
