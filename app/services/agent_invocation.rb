module AgentInvocation
  DEFAULT_TIMEOUT_SECONDS = 30.minutes.to_i
  # Kill the agent subprocess if it produces no output for this long.
  # Sized to accommodate long tool execs: a full test suite, a
  # `bundle install`, or a slow `git fetch` invoked from inside the
  # agent can legitimately silence the JSONL stream for many minutes.
  # The wall-clock DEFAULT_TIMEOUT_SECONDS (30 min) is the absolute
  # ceiling; 20 min of silence is the "wedged, not slow" heuristic.
  SILENT_TIMEOUT_SECONDS = 20.minutes.to_i
  # Fallback only for callers that don't pass max_turns. RunJob threads
  # the per-user ceiling (User#agent_max_turns) through every invocation
  # in production. Kept in sync with User::AGENT_MAX_TURNS_RANGE's
  # production default so direct callers don't get a surprising cap.
  DEFAULT_MAX_TURNS = 200

  ENV_FORWARD = %w[
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

  class Result
    attr_reader :turns, :exit_status, :timed_out, :is_error, :outcome,
                :final_text, :session_id, :transcript_jsonl, :transcript_path,
                :cost_usd, :input_tokens, :output_tokens,
                :cache_creation_input_tokens, :cache_read_input_tokens

    def initialize(turns:, exit_status:, timed_out:, is_error:, outcome:,
                   final_text:, session_id:, transcript_jsonl: nil,
                   transcript_path: nil, cost_usd: nil, input_tokens: nil,
                   output_tokens: nil, cache_creation_input_tokens: nil,
                   cache_read_input_tokens: nil)
      @turns = turns
      @exit_status = exit_status
      @timed_out = timed_out
      @is_error = is_error
      @outcome = outcome
      @final_text = final_text
      @session_id = session_id
      @transcript_jsonl = transcript_jsonl
      @transcript_path = transcript_path
      @cost_usd = cost_usd
      @input_tokens = input_tokens
      @output_tokens = output_tokens
      @cache_creation_input_tokens = cache_creation_input_tokens
      @cache_read_input_tokens = cache_read_input_tokens
    end

    def success? = !timed_out && exit_status == 0 && !is_error
  end
end
