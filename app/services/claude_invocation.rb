require "json"

class ClaudeInvocation
  def initialize(workspace_path, prompt:, oauth_token:,
                 log_sink: ->(_) { },
                 runner: nil,
                 timeout: AgentInvocation::DEFAULT_TIMEOUT_SECONDS,
                 max_turns: AgentInvocation::DEFAULT_MAX_TURNS,
                 mcp_config: nil,
                 resume_session_id: nil,
                 stop_requested: -> { false },
                 process_started: ->(_process) { })
    @workspace_path = workspace_path.to_s
    @prompt = prompt
    @oauth_token = oauth_token
    @log_sink = log_sink
    @runner = runner || method(:default_runner)
    @timeout = timeout
    @max_turns = max_turns
    @mcp_config = mcp_config
    @resume_session_id = resume_session_id
    @stop_requested = stop_requested
    @process_started = process_started
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
      resume_session_id: @resume_session_id,
      stop_requested: @stop_requested,
      process_started: @process_started
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
                     max_turns:, mcp_config: nil, resume_session_id: nil,
                     stop_requested: -> { false }, process_started: ->(_process) { })
    env = agent_env(oauth_token: oauth_token, workspace_path: workspace_path)
    cmd = [ "claude", "--print" ]
    # `--mcp-config <configs...>` is variadic — claude keeps consuming
    # subsequent positional args as additional configs until it sees
    # another flag. If we put it last, the prompt gets eaten as a
    # second "config" and claude bails with ENAMETOOLONG. Slot it in
    # *before* another flag (here, --output-format) so the variadic
    # terminates after one path. Same rule applies to --resume even
    # though it's a single-value flag — we keep it next to mcp-config
    # for symmetry and to leave the prompt as the only trailing arg.
    cmd += [ "--mcp-config", mcp_config ] if mcp_config
    cmd += [ "--resume", resume_session_id ] if resume_session_id
    cmd += [ "--output-format", "stream-json",
             "--verbose",
             "--dangerously-skip-permissions" ]
    # 0 (or nil) means "no cap" — omit --max-turns entirely. The
    # process timeout (AgentInvocation::DEFAULT_TIMEOUT_SECONDS) still bounds runaway
    # loops, so we're not unbounded on wall time even uncapped.
    cmd += [ "--max-turns", max_turns.to_s ] if max_turns && max_turns.positive?
    cmd += [ prompt ]

    metadata = {
      turns: nil, is_error: false, outcome: nil, final_text: nil, session_id: nil,
      cost_usd: nil, input_tokens: nil, output_tokens: nil,
      cache_creation_input_tokens: nil, cache_read_input_tokens: nil
    }
    current_run = Thread.current[:syrus_current_run]
    runner_result = ProcessRunner.new(
      env: env,
      command: cmd,
      chdir: workspace_path,
      timeout: timeout,
      silent_timeout: AgentInvocation::SILENT_TIMEOUT_SECONDS,
      kind: "agent",
      run: current_run,
      workflow: current_run&.workflow,
      stop_requested: stop_requested,
      on_spawned_process: process_started,
      on_output_line: ->(line) do
        update = process_event(line, log_sink)
        metadata.merge!(update.compact) if update
      end
    ).run

    AgentInvocation::Result.new(
      turns: metadata[:turns],
      exit_status: runner_result.exit_status,
      # A silent-timeout kill is, from the caller's perspective, the
      # same outcome as a wall-clock timeout: the agent didn't
      # complete. Surface it as `timed_out` so existing failure
      # handling in Steps::Implement (etc.) covers both cases without
      # any new branches.
      timed_out: runner_result.timed_out || runner_result.silent_timed_out,
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
      content = event.dig("message", "content") || []
      content.each do |block|
        case block["type"]
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
            tool_input: block["input"]
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
        { session_id: event["session_id"] } if event["session_id"]
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
end
