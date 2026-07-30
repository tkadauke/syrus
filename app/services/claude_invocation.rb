require "json"

class ClaudeInvocation
  def initialize(workspace_path, prompt:, oauth_token:,
                 log_sink: ->(_) { },
                 runner: nil,
                 timeout: AgentInvocation::DEFAULT_TIMEOUT_SECONDS,
                 max_turns: AgentInvocation::DEFAULT_MAX_TURNS,
                 mcp_config: nil,
                 image_paths: nil,
                 file_paths: nil,
                 resume_session_id: nil,
                 disallowed_tools: nil,
                 required_mcp_tools: nil,
                 model: nil,
                 effort_level: nil,
                 env: nil,
                 stop_requested: -> { false },
                 process_started: ->(_process) { },
                 on_session_id: ->(_session_id) { })
    @workspace_path = workspace_path.to_s
    @prompt = prompt
    @oauth_token = oauth_token
    @log_sink = log_sink
    @runner = runner || method(:default_runner)
    @timeout = timeout
    @max_turns = max_turns
    @mcp_config = mcp_config
    @image_paths = Array(image_paths).compact
    @file_paths = Array(file_paths).compact
    @resume_session_id = resume_session_id
    @disallowed_tools = Array(disallowed_tools).compact
    @required_mcp_tools = Array(required_mcp_tools).compact_blank.map(&:to_s)
    @model = model.to_s.strip.presence
    @effort_level = effort_level.to_s.presence
    @env = env || {}
    @stop_requested = stop_requested
    @process_started = process_started
    @on_session_id = on_session_id
  end

  def run
    @runner.call(
      workspace_path: @workspace_path,
      prompt: @prompt,
      oauth_token: @oauth_token,
      log_sink: @log_sink,
      timeout: @timeout,
      max_turns: @max_turns,
      mcp_config: @mcp_config,
      image_paths: @image_paths,
      file_paths: @file_paths,
      resume_session_id: @resume_session_id,
      disallowed_tools: @disallowed_tools,
      model: @model,
      effort_level: @effort_level,
      env: @env,
      stop_requested: @stop_requested,
      process_started: @process_started,
      on_session_id: @on_session_id
    )
  end

  private

  # Spawns `claude --print --output-format stream-json --verbose
  # --dangerously-skip-permissions --max-turns N "<prompt>"` in the
  # worktree with CLAUDE_CODE_OAUTH_TOKEN set. Streams readable assistant
  # text into log_sink, captures num_turns + is_error + subtype from the
  # final result event, kills the process after timeout.
  #
  # --dangerously-skip-permissions is intentional: the agent runs in an
  # isolated per-job worktree, never against the operator's checkout. Same
  # trust posture as letting a human dev pair on a branch.
  def default_runner(workspace_path:, prompt:, oauth_token:, log_sink:, timeout:,
                     max_turns:, mcp_config: nil, image_paths: nil, file_paths: nil, resume_session_id: nil,
                     env: nil,
                     disallowed_tools: nil,
                     model: nil,
                     effort_level: nil,
                     stop_requested: -> { false }, process_started: ->(_process) { },
                     on_session_id: ->(_session_id) { })
    env = agent_env(oauth_token: oauth_token, workspace_path: workspace_path).merge(env || {})
    ensure_session_on_disk(resume_session_id, workspace_path, log_sink) if resume_session_id.present?
    cmd = [ "claude", "--print" ]
    # The prompt is fed to claude over stdin (`stdin_data:` below), NOT as a
    # positional arg. A large prompt on argv — e.g. an adversarial_review step
    # that embeds a big diff — overruns Linux's 128 KiB per-argument limit
    # (MAX_ARG_STRLEN) and execve fails with Errno::E2BIG "Argument list too
    # long". stdin has no such ceiling. This also removes the old
    # `--mcp-config <configs...>` variadic hazard entirely: with no trailing
    # positional, claude cannot mistake the prompt for an extra mcp config,
    # so `--mcp-config`/`--resume` no longer need a following flag to fence
    # the variadic.
    cmd += [ "--mcp-config", mcp_config ] if mcp_config
    cmd += [ "--resume", resume_session_id ] if resume_session_id
    cmd += [ "--model", model ] if model.present?
    cmd += [ "--disallowedTools", *Array(disallowed_tools) ] if disallowed_tools.present?
    # Claude Code does not expose a stable `--image` flag. Chat image
    # attachments are saved in the workspace and surfaced in the prompt as
    # paths the agent can inspect with its normal read tools.
    Array(file_paths).each { |path| cmd += [ "--file", path ] }
    cmd += [ "--output-format", "stream-json",
             "--verbose",
             "--dangerously-skip-permissions" ]
    # 0 (or nil) means "no cap" — omit --max-turns entirely. The
    # process timeout (AgentInvocation::DEFAULT_TIMEOUT_SECONDS) still bounds runaway
    # loops, so we're not unbounded on wall time even uncapped.
    cmd += [ "--max-turns", max_turns.to_s ] if max_turns && max_turns.positive?
    cmd += [ "--effort", effort_level ] if effort_level.present? && effort_level != "none"

    metadata = {
      turns: nil, is_error: false, outcome: nil, final_text: nil, session_id: nil,
      cost_usd: nil, input_tokens: nil, output_tokens: nil,
      cache_creation_input_tokens: nil, cache_read_input_tokens: nil
    }
    mcp_server_failed = false
    current_run = Thread.current[:syrus_current_run]
    runner_result = ProcessRunner.new(
      env: env,
      command: cmd,
      stdin_data: prompt,
      chdir: workspace_path,
      timeout: timeout,
      silent_timeout: AgentInvocation::SILENT_TIMEOUT_SECONDS,
      kind: "agent",
      run: current_run,
      workflow: current_run&.workflow,
      stop_requested: -> { mcp_server_failed || stop_requested.call },
      on_spawned_process: process_started,
      on_output_line: ->(line) do
        update = process_event(line, log_sink)
        if update
          mcp_server_failed = true if update.delete(:mcp_server_failed)
          update = update.compact
          if update[:is_error] && update[:outcome] == "success"
            update[:outcome] = metadata[:outcome].presence || "api_error"
          end
          if update[:session_id] && metadata[:session_id].nil?
            on_session_id.call(update[:session_id])
          end
          metadata.merge!(update)
        end
      end
    ).run
    if mcp_server_failed
      metadata[:is_error] = true
      metadata[:outcome] = "mcp_sidecar_failed"
      metadata[:final_text] = nil
    end

    # If the provider already emitted a successful result event, any
    # subsequent timeout is cleanup overhead (e.g. a lingering background
    # watcher keeping the claude process alive after the agent finished).
    # Don't surface it as a timeout — the agent's work is already done.
    provider_succeeded = metadata[:outcome].present? && !metadata[:is_error]
    cleanup_timeout    = provider_succeeded && (runner_result.timed_out || runner_result.silent_timed_out)

    AgentInvocation::Result.new(
      turns: metadata[:turns],
      exit_status: cleanup_timeout ? 0 : runner_result.exit_status,
      timed_out: !cleanup_timeout && (runner_result.timed_out || runner_result.silent_timed_out),
      is_error: metadata[:is_error],
      outcome: metadata[:outcome],
      final_text: metadata[:final_text],
      session_id: metadata[:session_id],
      cost_usd: metadata[:cost_usd],
      input_tokens: metadata[:input_tokens],
      output_tokens: metadata[:output_tokens],
      cache_creation_input_tokens: metadata[:cache_creation_input_tokens],
      cache_read_input_tokens: metadata[:cache_read_input_tokens]
    )
  end

  def ensure_session_on_disk(session_id, workspace_path, log_sink)
    path = ClaudeSession.canonical_path_for(
      home: ENV.fetch("HOME", "/root"),
      cwd: workspace_path,
      session_id: session_id
    )
    return if File.exist?(path)

    session = ClaudeSession.find_by(session_id: session_id)
    return unless session&.transcript_jsonl.present?

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, session.transcript_jsonl)
    log_sink.call("[ClaudeInvocation] restored session #{session_id} from DB to #{path}", kind: "system")
  rescue StandardError => e
    log_sink.call("[ClaudeInvocation] session restore failed for #{session_id}: #{e.message}", kind: "system")
  end

  def agent_env(oauth_token:, workspace_path:)
    forwarded = ProcessRunner.forwarded_env(
      AgentInvocation::ENV_FORWARD,
      extra: WorkspaceDependencyEnv.for(workspace_path).merge("CLAUDE_CODE_OAUTH_TOKEN" => oauth_token)
    )
    # If the worktree itself is a Bundler project (its own Gemfile),
    # point BUNDLE_GEMFILE at it explicitly. Saves the agent from
    # having to figure out where bundler should look. If the
    # worktree isn't Ruby at all, leave it unset.
    workspace_gemfile = File.join(workspace_path.to_s, "Gemfile")
    forwarded["BUNDLE_GEMFILE"] = workspace_gemfile if File.exist?(workspace_gemfile)
    forwarded
  end

  # Returns a hash of metadata updates if the line was a result event.
  # Streams claude's output into log_sink with a `kind:` label so the
  # UI can filter by row type:
  #
  #   "assistant_text" — agent's narrative
  #   "tool_call"      — abbreviated tool_use ("● Bash(rg foo)")
  #   "tool_result"    — abbreviated tool_result ("  ⎿ output…")
  #   "system"         — meta lines (the [result] event)
  #
  # Logging tool_call + tool_result events alongside assistant_text
  # is critical for heartbeat reliability: a step doing 99 Bash
  # calls in a row used to look silent (only assistant text bumped
  # the heartbeat) and could trip the reaper. With this branch
  # logging every meaningful event, every turn moves the
  # heartbeat. Default UI hides tool_call/tool_result rows behind
  # a toggle; the data is always there.
  def process_event(line, log_sink)
    event = JSON.parse(line.strip)
    case event["type"]
    when "assistant"
      if api_error_event?(event)
        message = assistant_text_for(event).presence || "Claude returned an API error."
        detail = api_error_message(event, message)
        log_sink.call(detail, kind: "system")
        if ProviderUsageLimit.detect?(detail)
          return {
            is_error: true,
            outcome: ProviderUsageLimit::OUTCOME,
            final_text: detail
          }
        end

        return {
          is_error: true,
          outcome: event["error"].presence || "api_error",
          final_text: nil
        }
      end

      content = event.dig("message", "content") || []
      content.each do |block|
        case block["type"]
        when "thinking"
          log_sink.call(
            block["thinking"],
            kind: "thinking",
            thinking: block["thinking"],
            signature: block["signature"]
          ) if block["thinking"].present?
        when "text"
          log_sink.call(block["text"], kind: "assistant_text") if block["text"].present?
        when "tool_use"
          log_sink.call(
            AgentEventAbbreviator.tool_use(
              block["name"],
              block["input"],
              path_roots: [ @workspace_path ]
            ),
            kind: "tool_call",
            tool_name: block["name"],
            tool_input: block["input"],
            tool_use_id: block["id"]
          )
        end
      end
      nil
    when "user"
      # User events in the JSONL include tool_result blocks (the
      # response to a previous tool_use). Surface those as
      # abbreviated lines so the operator sees the agent's
      # actions interleaved with their results.
      content = event.dig("message", "content")
      if content.is_a?(Array)
        content.each do |block|
          next unless block["type"] == "tool_result"
          log_sink.call(
            AgentEventAbbreviator.tool_result(block["content"], error: block["is_error"] == true),
            kind: "tool_result",
            tool_result_content: block["content"],
            tool_result_error: block["is_error"] == true,
            tool_use_id: block["tool_use_id"]
          )
        end
      end
      nil
    when "system"
      # init carries the session_id we'll need to resume later. Other
      # system subtypes are noise.
      if event["subtype"] == "init"
        servers = nil
        # Log MCP server registration state so failed runs (esp.
        # `--resume`d ones) can be diagnosed: status=pending or
        # missing-from-list = the tool won't be callable. Logged
        # unconditionally so the post-mortem doesn't depend on
        # remembering to enable a debug flag.
        if event["mcp_servers"]
          servers = event["mcp_servers"].map { |server| { "name" => server["name"], "status" => server["status"] } }
          log_sink.call(
            "[mcp_servers] #{servers.map { |s| "#{s['name']}=#{s['status']}" }.join(', ')}",
            kind: "system",
            mcp_servers: servers
          )
        end
        updates = {}
        updates[:session_id] = event["session_id"] if event["session_id"]
        if (required_update = required_mcp_tools_update(servers, log_sink))
          updates.merge!(required_update)
        elsif servers&.any? { |server| server["status"] == "failed" }
          updates.merge!(
            mcp_server_failed: true,
            is_error: true,
            outcome: "mcp_sidecar_failed",
            final_text: nil
          )
        end
        updates.presence
      end
    when "result"
      usage = event["usage"] || {}
      log_sink.call(
        "[result] subtype=#{event['subtype']}, is_error=#{event['is_error']}, turns=#{event['num_turns']}, duration_ms=#{event['duration_ms']}, total_cost_usd=#{event['total_cost_usd']}",
        kind: "system"
      )
      usage_updates = {
        cost_usd: event["total_cost_usd"],
        input_tokens: usage["input_tokens"],
        output_tokens: usage["output_tokens"],
        cache_creation_input_tokens: usage["cache_creation_input_tokens"],
        cache_read_input_tokens: usage["cache_read_input_tokens"]
      }.compact

      {
        turns: event["num_turns"],
        is_error: event["is_error"],
        outcome: event["subtype"],
        final_text: event["result"]
      }.merge(usage_updates)
    else
      nil
    end
  rescue JSON::ParserError
    log_sink.call(line.chomp)
    nil
  end

  def api_error_event?(event)
    event["isApiErrorMessage"] == true || event["apiErrorStatus"].present? || event["error"].present?
  end

  def required_mcp_tools_update(servers, log_sink)
    return if @required_mcp_tools.empty?

    sidecar = servers&.find { |server| server["name"] == "syrus-mcp-sidecar" }
    status = sidecar&.fetch("status", nil).presence || "missing"
    return if status == "connected" || status == "pending"

    log_sink.call(
      "[mcp_required] syrus-mcp-sidecar=#{status}; required tools unavailable: #{@required_mcp_tools.join(', ')}",
      kind: "system"
    )
    {
      mcp_server_failed: true,
      is_error: true,
      outcome: "mcp_sidecar_failed",
      final_text: nil
    }
  end

  def assistant_text_for(event)
    Array(event.dig("message", "content")).filter_map do |block|
      block["text"] if block["type"] == "text"
    end.join("\n")
  end

  def api_error_message(event, message)
    status = event["apiErrorStatus"].presence
    if status.to_i == 401 || event["error"].to_s == "authentication_failed"
      detail = status ? "#{status} #{message}" : message
      return "Claude authentication failed. Refresh the Claude OAuth token in Credentials, then send the message again. (#{detail})"
    end

    detail = status ? "HTTP #{status}: #{message}" : message
    "Claude API error: #{detail}"
  end
end
