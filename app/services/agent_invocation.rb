require "json"
require "open3"

class AgentInvocation
  DEFAULT_TIMEOUT_SECONDS = 30.minutes.to_i
  # Fallback only for callers that don't pass max_turns. RunJob threads
  # the per-user ceiling (User#agent_max_turns) through every invocation
  # in production. Kept in sync with User::AGENT_MAX_TURNS_RANGE's
  # production default so direct callers don't get a surprising cap.
  DEFAULT_MAX_TURNS = 200

  # Outcome of one claude invocation. `turns` is parsed from the final
  # stream-json result event; `outcome` is the result event's subtype
  # ("success" / "error_max_turns" / "error_during_execution") and
  # `is_error` mirrors its is_error boolean. `final_text` is the agent's
  # final assistant text from the result event — useful for single-shot
  # callers (PR summarizer, etc.) that want the response without
  # re-aggregating the streamed assistant chunks.
  class Result
    attr_reader :turns, :exit_status, :timed_out, :is_error, :outcome,
                :final_text, :session_id, :transcript_jsonl, :transcript_path

    def initialize(turns:, exit_status:, timed_out:, is_error:, outcome:,
                   final_text:, session_id:, transcript_jsonl: nil,
                   transcript_path: nil)
      @turns = turns
      @exit_status = exit_status
      @timed_out = timed_out
      @is_error = is_error
      @outcome = outcome
      @final_text = final_text
      @session_id = session_id
      @transcript_jsonl = transcript_jsonl
      @transcript_path = transcript_path
    end

    def success? = !timed_out && exit_status == 0 && !is_error
  end

  def initialize(workspace_path, prompt:, oauth_token:,
                 log_sink: ->(_) { },
                 runner: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 max_turns: DEFAULT_MAX_TURNS,
                 mcp_config: nil,
                 resume_session_id: nil)
    @workspace_path = workspace_path.to_s
    @prompt = prompt
    @oauth_token = oauth_token
    @log_sink = log_sink
    @runner = runner || method(:default_runner)
    @timeout = timeout
    @max_turns = max_turns
    @mcp_config = mcp_config
    @resume_session_id = resume_session_id
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
      resume_session_id: @resume_session_id
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
  def default_runner(workspace_path:, prompt:, oauth_token:, log_sink:, timeout:, max_turns:, mcp_config: nil, resume_session_id: nil)
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
    # process timeout (DEFAULT_TIMEOUT_SECONDS) still bounds runaway
    # loops, so we're not unbounded on wall time even uncapped.
    cmd += [ "--max-turns", max_turns.to_s ] if max_turns && max_turns.positive?
    cmd += [ prompt ]

    metadata = { turns: nil, is_error: false, outcome: nil, final_text: nil, session_id: nil }
    timed_out = false

    # `unsetenv_others: true` means: child gets EXACTLY the env we
    # pass (plus nothing inherited). Without it, Open3 *merges* env
    # into the parent's environment, so the worker container's
    # BUNDLE_GEMFILE / BUNDLE_PATH / RAILS_ENV / etc. all leak into
    # the agent's claude subprocess. Then anything Bundler-aware the
    # agent runs (`bundle exec`, `bundle install`, even
    # `bin/rails ...`) targets Syrus's own /rails/Gemfile, not the
    # target repo's worktree. See issue #104 + Run #107 for the
    # incident this caused (agent "fixed" Syrus's Gemfile.lock,
    # which then broke the worker pod's bundle until next deploy).
    Open3.popen2e(env, *cmd, chdir: workspace_path, unsetenv_others: true) do |stdin, output, wait_thread|
      stdin.close

      killer = Thread.new do
        sleep timeout
        timed_out = true
        kill_tree(wait_thread.pid)
      end

      output.each_line do |line|
        update = process_event(line, log_sink)
        metadata.merge!(update.compact) if update
      end

      killer.kill
      status = wait_thread.value
      Result.new(
        turns: metadata[:turns],
        exit_status: status.exitstatus,
        timed_out: timed_out,
        is_error: metadata[:is_error],
        outcome: metadata[:outcome],
        final_text: metadata[:final_text],
        session_id: metadata[:session_id]
      )
    end
  end

  # Env vars Syrus's worker forwards into the agent's claude
  # subprocess. Allowlist (not denylist) so any env we haven't
  # specifically considered — including secrets baked into the worker
  # image — never leak across the boundary.
  #
  # Anything Bundler/Rails/Syrus-specific is intentionally absent. If
  # the agent needs to drive Bundler in the worktree, it'll set up
  # its own BUNDLE_GEMFILE pointing at the worktree's Gemfile.
  AGENT_ENV_FORWARD = %w[
    HOME
    USER
    LOGNAME
    PATH
    TERM
    LANG
    LC_ALL
    LC_CTYPE
    TZ
    HOSTNAME
    TMPDIR
    SHELL
  ].freeze

  def agent_env(oauth_token:, workspace_path:)
    forwarded = ENV.slice(*AGENT_ENV_FORWARD)
    forwarded["CLAUDE_CODE_OAUTH_TOKEN"] = oauth_token
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
            AgentEventAbbreviator.tool_use(block["name"], block["input"]),
            kind: "tool_call"
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
            kind: "tool_result"
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
          log_sink.call(
            "[mcp_servers] #{event['mcp_servers'].map { |s| "#{s['name']}=#{s['status']}" }.join(', ')}",
            kind: "system"
          )
        end
        { session_id: event["session_id"] } if event["session_id"]
      end
    when "result"
      log_sink.call(
        "[result] subtype=#{event['subtype']}, is_error=#{event['is_error']}, turns=#{event['num_turns']}, duration_ms=#{event['duration_ms']}",
        kind: "system"
      )
      {
        turns: event["num_turns"],
        is_error: event["is_error"],
        outcome: event["subtype"],
        final_text: event["result"]
      }
    else
      nil
    end
  rescue JSON::ParserError
    log_sink.call(line.chomp)
    nil
  end

  def kill_tree(pid)
    Process.kill("TERM", pid)
    sleep 5
    Process.kill("KILL", pid) rescue nil
  rescue Errno::ESRCH
    # Already dead; nothing to do.
  end
end
