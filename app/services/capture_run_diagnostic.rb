require "fileutils"

# Snapshots the world at the moment a Run failed: the exception, a
# pile of git state from the worktree, a filtered environment, and
# repo/job metadata. Persists it as a RunDiagnostic so the operator
# (admin) can see what happened even after the worktree's gone.
#
# Best-effort. Any error inside the capture is logged and swallowed —
# the Run was already failing; we don't want to double-fault inside
# RunJob's rescue block.
class CaptureRunDiagnostic
  # Allowlisted env var names. Anything not in this list is dropped
  # from the snapshot — we don't want to accidentally persist
  # SYRUS_DATABASE_PASSWORD, RAILS_MASTER_KEY, the user's
  # claude_oauth_token, or anything else with secret bits.
  #
  # Names with `KUBERNETES_` prefix are matched by prefix below
  # (handles SERVICE_HOST, PORT_443_TCP_*, etc.).
  ENV_ALLOWLIST = %w[
    HOME
    USER
    PWD
    HOSTNAME
    LANG
    LC_ALL
    TZ
    PATH
    RAILS_ENV
    RAILS_LOG_LEVEL
    RAILS_MAX_THREADS
    RAILS_LOG_TO_STDOUT
    SYRUS_DATA_ROOT
    DB_HOST
    POD_NAME
    POD_NAMESPACE
    NODE_NAME
    GIT_SHA
  ].freeze

  ENV_ALLOWLIST_PREFIXES = %w[KUBERNETES_].freeze

  # Tail caps for transcript-style outputs that could otherwise blow
  # up DB row size on a chatty repo (large `git log` history,
  # 5000-line `git status` after a `git rm -r .` mistake, etc.).
  GIT_OUTPUT_TAIL = 8_000

  def self.capture(run, exception, workspace: nil)
    new(run, exception, workspace: workspace).call
  end

  def initialize(run, exception, workspace: nil)
    @run = run
    @exception = exception
    @workspace = workspace
  end

  def call
    return unless @run && @exception

    # Idempotency guard. RunJob can theoretically rescue the same
    # exception path more than once during a chaotic shutdown; we'd
    # rather keep the first snapshot than overwrite with whatever
    # came after.
    return if RunDiagnostic.exists?(run_id: @run.id)

    RunDiagnostic.create!(
      run: @run,
      error_class: @exception.class.name,
      error_message: truncate(@exception.message, 4_000),
      error_backtrace: format_backtrace,
      git_snapshot: capture_git_snapshot,
      environment_snapshot: capture_environment_snapshot,
      repo_snapshot: capture_repo_snapshot
    )
  rescue StandardError => e
    Rails.logger.warn("[CaptureRunDiagnostic] failed for Run ##{@run&.id}: #{e.class}: #{e.message}")
    nil
  end

  private

  def format_backtrace
    return nil unless @exception.backtrace
    @exception.backtrace.first(50).join("\n")
  end

  def capture_git_snapshot
    path = @workspace&.path
    return { "note" => "no workspace (Run failed before setup completed)" } unless path && File.directory?(path)

    {
      "head"            => safe_git("rev-parse", "HEAD",                          chdir: path),
      "symbolic_head"   => safe_git("symbolic-ref", "--short", "HEAD",            chdir: path),
      "branch_show"     => safe_git("branch", "--show-current",                   chdir: path),
      "status"          => safe_git("status", "--porcelain=v1", "-uall",          chdir: path),
      "log_recent"      => safe_git("log", "--oneline", "-20",                    chdir: path),
      "branches_local"  => safe_git("branch", "--list",                           chdir: path),
      "branches_remote" => safe_git("branch", "--remotes",                        chdir: path),
      "merge_base_main" => safe_git("merge-base",
                                    "origin/#{@run.job.repository.default_branch}",
                                    "HEAD",                                       chdir: path),
      "remote_v"        => safe_git("remote", "-v",                               chdir: path)
    }
  end

  # Run a git command, never raising; on failure (incl. the worktree
  # being gone or in a corrupt state), capture the error string in
  # the snapshot value. The whole point of this service is to
  # snapshot a failing run, so capturing what FAILS in git too is
  # essential information.
  def safe_git(*args, chdir:)
    output = GitRunner.new.run(*args, chdir: chdir.to_s)
    output.last(GIT_OUTPUT_TAIL)
  rescue StandardError => e
    "(#{e.class}: #{truncate(e.message, 600)})"
  end

  def capture_environment_snapshot
    ENV.each_with_object({}) do |(k, v), acc|
      next unless ENV_ALLOWLIST.include?(k) || ENV_ALLOWLIST_PREFIXES.any? { |p| k.start_with?(p) }
      acc[k] = v.to_s
    end.merge(
      "ruby_version"  => RUBY_VERSION,
      "rails_version" => Rails.version,
      "git_version"   => safe_command(%w[git --version])
    )
  end

  def safe_command(argv)
    require "open3"
    out, _err, status = Open3.capture3(*argv)
    status.success? ? out.strip : "(exit #{status.exitstatus})"
  rescue StandardError => e
    "(#{e.class}: #{e.message})"
  end

  def capture_repo_snapshot
    job = @run.job
    {
      "job_id"           => job&.id,
      "job_kind"         => job&.kind,
      "job_state"        => job&.state,
      "job_branch"       => job&.branch_name,
      "job_pr_number"    => job&.pr_number,
      "job_issue_number" => job&.issue_number,
      "scheduled_task_id" => job&.scheduled_task_id,
      "repository_slug"  => job&.repository&.slug,
      "default_branch"   => job&.repository&.default_branch,
      "run_trigger_kind" => @run.trigger_kind,
      "run_state"        => @run.state,
      "run_started_at"   => @run.started_at&.iso8601,
      "run_turns"        => @run.agent_turns,
      "run_outcome"      => @run.agent_outcome,
      "command_spans"    => command_spans_snapshot,
      "workspace_path"   => @workspace&.path&.to_s
    }
  end

  def command_spans_snapshot
    @run.command_spans.ordered.limit(50).map do |span|
      {
        "id" => span.id,
        "sequence" => span.sequence,
        "name" => span.name,
        "command_excerpt" => truncate(CommandRedactor.redact(span.command_excerpt), 300),
        "started_at" => span.started_at&.iso8601,
        "finished_at" => span.finished_at&.iso8601,
        "duration_ms" => span.duration_ms,
        "exit_status" => span.exit_status,
        "outcome" => span.outcome,
        "hostname" => span.hostname,
        "metadata" => CommandRedactor.redact_value(span.metadata)
      }
    end
  end

  def truncate(string, limit)
    s = string.to_s
    return s if s.length <= limit
    "#{s[0, limit]}... [truncated #{s.length - limit} chars]"
  end
end
