class GitRunner
  # Redacts tokens out of any string that contains a
  # `https://x-access-token:TOKEN@github.com/...` URL — the form
  # WorkflowWorkspace + push/fetch helpers pass when they need
  # authenticated git.
  # Applied to:
  #   - argv stored on GitError (so the exception message is clean
  #     when it bubbles into JobLog / Solid Queue's failed_executions)
  #   - every line streamed to log_sink + captured into `output`
  #     (git prints the full URL in some network-error messages,
  #     e.g. "fatal: unable to access 'https://x-access-token:T@…'")
  DARWIN_TEMP_DIR_WARNING_PATTERN =
    /\Agit: warning: confstr\(\) failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using \/tmp instead\s*\z/.freeze

  # Wall-clock ceiling for any git operation. Network-bound clones /
  # fetches against very large repos can be slow; 10 minutes covers
  # the realistic upper end. ProcessRunner's aliveness probe still
  # catches the "git process died, child held the pipe" case faster.
  DEFAULT_TIMEOUT = 10.minutes

  def self.redact(text)
    CommandRedactor.redact(text)
  end

  def self.utf8(text)
    CommandRedactor.utf8(text)
  end

  def self.ignorable_output_line?(line)
    line.to_s.match?(DARWIN_TEMP_DIR_WARNING_PATTERN)
  end

  class GitError < StandardError
    attr_reader :command, :exit_status, :output

    OUTPUT_TAIL_LIMIT = 1500 # chars; enough to surface git's "fatal: ..." line(s)

    def initialize(command, exit_status, output)
      @command = command.map { |a| GitRunner.redact(a) }
      @exit_status = exit_status
      @output = GitRunner.redact(output)
      super(build_message)
    end

    private

    # Surface the last chunk of git's stdout+stderr in the message so
    # `e.message` (what RunJob's rescue logs) actually tells you what
    # went wrong, instead of "git diff main...HEAD exited 128" with no
    # context. Tail rather than head — git's "fatal: ..." line is
    # typically the last thing emitted.
    def build_message
      base = "git #{@command.join(' ')} exited #{@exit_status}"
      tail = @output.to_s.strip
      return base if tail.empty?
      tail = "...#{tail.last(OUTPUT_TAIL_LIMIT)}" if tail.length > OUTPUT_TAIL_LIMIT
      "#{base}\n#{tail}"
    end
  end

  # log_sink: a callable that receives each output line (stdout+stderr merged).
  # Defaults to a no-op so unit tests don't need to wire one up.
  def initialize(log_sink: ->(_line) { }, env: {})
    @log_sink = log_sink
    @env = env
  end

  # run("clone", "--bare", url, dest, chdir: nil)
  # Per-call env is merged with the instance env (per-call wins).
  # Useful for one-shot flags like GIT_TERMINAL_PROMPT=0 that you
  # only want on git operations that talk to a remote.
  def run(*args, chdir: nil, env: {}, timeout: DEFAULT_TIMEOUT)
    cmd = [ "git", *args.map(&:to_s) ]
    output = +""
    log_sink = @log_sink
    current_run = Thread.current[:syrus_current_run]

    # Route through ProcessRunner so the aliveness probe, kill switch,
    # SpawnedProcess registration, and heartbeat all apply to git ops
    # too — same coverage as agent and grader subprocesses. Without
    # this, a wedged `git fetch` would hold a worker thread silently.
    result = ProcessRunner.new(
      env: @env.merge(env),
      command: cmd,
      chdir: chdir || Dir.pwd,
      timeout: timeout.to_i,
      kind: "git",
      run: current_run,
      workflow: current_run&.workflow,
      on_output_line: ->(raw_line) do
        line = self.class.redact(raw_line)
        next if self.class.ignorable_output_line?(line)

        output << line
        log_sink.call(line)
      end
    ).run

    unless result.success?
      raise GitError.new(args, result.exit_status || -1, output)
    end

    output
  end

  # Sets the local commit author for the checkout at `chdir`. `identity` is any
  # object responding to #git_name / #git_email (e.g. BotIdentity). Centralizes
  # the two `git config --local user.*` calls the git services each repeated.
  def configure_author(identity, chdir:)
    run("config", "--local", "user.name", identity.git_name, chdir: chdir)
    run("config", "--local", "user.email", identity.git_email, chdir: chdir)
  end
end
