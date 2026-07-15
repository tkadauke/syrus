module Steps
  # First step in Initial / Retry / PrFeedback / CiFailure
  # workflows. Runs deterministic setup work in the workspace
  # BEFORE handing off to the agent — package-manager installs
  # mostly (`bundle install`, `npm ci`, etc.) so the agent doesn't
  # burn turns/tokens watching dependencies download.
  #
  # Source of commands: RepoPrepPlan reads `.syrus.yml` from the
  # repo root, falls back to auto-detect on common lockfile
  # signals. Empty plan = step succeeds with a one-line "nothing
  # to do" message — chain shape stays uniform across workflows
  # whether or not the repo opts in.
  #
  # Per-command timeout caps a hung install so the workflow can
  # fail loudly instead of pegging the worker thread until the
  # reaper trips.
  class Prepare < Base
    PER_COMMAND_TIMEOUT = 10.minutes.to_i
    MISE_INSTALL_TIMEOUT = 5.minutes.to_i
    OUTPUT_TAIL_BYTES = 8.kilobytes

    MISE_VERSION_FILES = %w[
      .tool-versions
      .mise.toml
      .ruby-version
      .python-version
      .node-version
      .go-version
    ].freeze

    # Mirror of AgentInvocation::ENV_FORWARD. Prep commands
    # run with EXACTLY this env (unsetenv_others: true) so the
    # worker pod's BUNDLE_PATH=/usr/local/bundle, BUNDLE_DEPLOYMENT=1,
    # BUNDLE_WITHOUT="development:test", RAILS_ENV=production, etc.
    # don't leak into a `bundle install` that's supposed to install
    # the target repo's gems (incl. test gems) into the workspace.
    # Same posture the agent gets — predictable, repo-independent.
    PREP_ENV_FORWARD = %w[
      HOME USER LOGNAME PATH TERM LANG LC_ALL LC_CTYPE TZ HOSTNAME TMPDIR SHELL
      MISE_DATA_DIR
    ].freeze

    def call
      workspace.setup
      sync_fork_with_upstream! if repository.upstream_repository_id.present?
      run_mise_install if mise_version_file?
      plan = RepoPrepPlan.for(workspace.path)

      log("[prepare] source: #{plan.source}")
      log("[prepare] note: #{plan.note}") if plan.note

      if plan.commands.empty?
        log("[prepare] no commands to run; skipping")
        return
      end

      plan.commands.each_with_index do |cmd, i|
        log("[prepare] (#{i + 1}/#{plan.commands.size}) $ #{cmd}")
        next if run_shell(cmd, guessed: plan.guessed?)

        # Reached only on a soft-failed *guessed* command (an explicit
        # .syrus.yml command raises instead). Stop running further
        # auto-detected commands and hand the workspace to the agent
        # as-is — the agent can add a `.syrus.yml prepare:` list or fix
        # the lockfile from inside the run.
        log("[prepare] guessed setup command failed — handing off to the agent without it. " \
            "Add a .syrus.yml `prepare:` list (or fix the lockfile) to take control of setup.")
        return
      end

      log("[prepare] all commands completed successfully")
    end

    private

    # `bash -c` so quoting / pipelines / && in commands work.
    # cwd = workspace path. Env scrubbed via PREP_ENV_FORWARD +
    # unsetenv_others. Streams stdout+stderr (popen2e merges them)
    # into JobLog one line at a time so the operator can watch the
    # install live. Hard timeout via a watcher thread that SIGTERMs
    # the process tree if it exceeds the budget.
    # Returns true on success. On failure: a guessed (auto-detected)
    # command records a soft failure and returns false so the chain
    # continues to the agent; an explicit `.syrus.yml` command raises
    # StepFailed so the operator sees their config break loudly.
    def run_shell(cmd, guessed:)
      buffer = new_log_buffer
      tail = +""
      result = ProcessRunner.new(
        env: env,
        command: [ "bash", "-c", cmd ],
        chdir: workspace.path,
        timeout: PER_COMMAND_TIMEOUT,
        kind: "prepare",
        run: run,
        workflow: workflow,
        on_output_chunk: ->(chunk) {
          append_output_tail(tail, chunk)
          stream_buffered_chunk(buffer, chunk)
        }
      ).run
      flush_log_buffer(buffer)

      return true if result.success? && !result.timed_out

      failure = prepare_failure_payload(cmd, result, tail)
      if guessed
        record_prepare_soft_failure!(failure)
        false
      else
        record_prepare_failure!(failure)
        raise StepFailed, prepare_failure_message(failure)
      end
    end

    def append_output_tail(tail, chunk)
      tail << chunk.to_s
      overflow = tail.bytesize - OUTPUT_TAIL_BYTES
      tail.replace(tail.safe_byteslice(-OUTPUT_TAIL_BYTES, OUTPUT_TAIL_BYTES)) if overflow.positive?
    end

    def prepare_failure_payload(cmd, result, tail)
      {
        "command" => cmd,
        "workdir" => workspace.path.to_s,
        "exit_status" => result.exit_status,
        "timed_out" => result.timed_out?,
        "stopped" => result.stopped?,
        "operator_killed" => result.operator_killed?,
        "aliveness_failed" => result.aliveness_failed?,
        "duration_s" => result.duration_s&.round(2),
        "output_tail" => compact_output_tail(tail)
      }
    end

    def record_prepare_failure!(failure)
      step.update!(details: (step.details || {}).merge("prepare_failure" => failure))
      workflow.set_artifact!("prepare_failure", failure)
      log("[prepare] failure: #{prepare_failure_message(failure)}")
    end

    # Same record shape as a hard failure, tagged `soft` so the UI can
    # frame it as "Syrus skipped a guessed step" rather than "setup
    # failed before the agent started" — the agent does still run.
    def record_prepare_soft_failure!(failure)
      soft = failure.merge("soft" => true)
      step.update!(details: (step.details || {}).merge("prepare_failure" => soft))
      workflow.set_artifact!("prepare_failure", soft)
      log("[prepare] WARNING (guessed command, non-fatal): #{prepare_failure_message(failure)}")
    end

    def prepare_failure_message(failure)
      status = if failure["timed_out"]
        "timed out after #{PER_COMMAND_TIMEOUT}s"
      elsif failure["operator_killed"]
        "operator killed"
      elsif failure["stopped"]
        "stopped"
      elsif failure["aliveness_failed"]
        "process disappeared"
      else
        "exit #{failure["exit_status"] || "unknown"}"
      end

      message = "prepare command failed (#{status}) in #{failure["workdir"]}: #{failure["command"]}"
      tail = failure["output_tail"].to_s
      return message if tail.blank?

      "#{message}\nOutput tail:\n#{tail}"
    end

    def compact_output_tail(tail)
      tail.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?").strip
    end

    # Read `io` until EOF, batching writes into JobLog. Active streams flush
    # only when the buffer reaches LOG_FLUSH_MAX_BUF; the IO.select timeout
    # shrinks toward the next eligible flush deadline so quiet streams still
    # flush promptly.
    def stream_buffered(io)
      buffer = new_log_buffer
      loop do
        timeout = next_log_flush_timeout(buffer[:content], buffer[:last_flush])
        ready, = IO.select([ io ], nil, nil, timeout)

        unless ready
          flush_log_buffer(buffer) if log_flush_ready?(buffer[:content], buffer[:last_flush])
          next
        end

        begin
          stream_buffered_chunk(buffer, io.read_nonblock(16 * 1024))
        rescue IO::WaitReadable
          next
        rescue EOFError
          break
        end
      end
    ensure
      flush_log_buffer(buffer) if buffer
    end

    def new_log_buffer
      { content: +"", last_flush: Time.current }
    end

    def stream_buffered_chunk(buffer, chunk)
      buffer[:content] << chunk
      flush_log_buffer(buffer) if buffer[:content].bytesize >= LOG_FLUSH_MAX_BUF
    end

    def flush_log_buffer(buffer)
      return if buffer[:content].empty?

      log(buffer[:content].chomp, kind: "system")
      buffer[:content].clear
      buffer[:last_flush] = Time.current
    end

    def next_log_flush_timeout(buffer, last_flush)
      elapsed = Time.current - last_flush
      deadlines = [ LOG_FLUSH_INTERVAL ]
      deadlines << LOG_FLUSH_MIN_GAP if buffer.bytesize >= LOG_FLUSH_BYTES
      timeout = deadlines.min - elapsed
      timeout.positive? ? timeout : 0
    end

    # Syncs the fork's default branch with its upstream before running
    # prepare commands so the agent works against up-to-date code.
    # Uses merge (not rebase) to preserve the fork's commit history.
    # On conflict, raises StepFailed with manual-sync instructions.
    def sync_fork_with_upstream!
      upstream = repository.upstream_repository
      upstream_branch = upstream.default_branch
      fork_default = repository.default_branch
      syrus_branch = workspace.branch_name
      chdir = workspace.path.to_s

      log("[prepare] fork sync: syncing #{repository.slug} with upstream #{upstream.slug}@#{upstream_branch}")

      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })

      # Fetch upstream branch without adding a persistent remote; FETCH_HEAD
      # holds the result so we avoid writing to .git/config.
      git.run("fetch", upstream.remote_url, upstream_branch, chdir: chdir)

      git.run("checkout", fork_default, chdir: chdir)
      sha_before = GitRunner.new.run("rev-parse", "HEAD", chdir: chdir).strip

      begin
        git.run("merge", "--no-edit", "FETCH_HEAD", chdir: chdir)
      rescue GitRunner::GitError => e
        abort_fork_merge(git, chdir)
        git.run("checkout", syrus_branch, chdir: chdir)
        record_fork_sync_conflict!(upstream, upstream_branch, e.output)
        raise StepFailed, fork_sync_conflict_message(upstream, upstream_branch)
      end

      sha_after = GitRunner.new.run("rev-parse", "HEAD", chdir: chdir).strip

      if sha_before == sha_after
        log("[prepare] fork sync: #{repository.slug} is already up-to-date with #{upstream.slug}")
      else
        push_user = job.owner_user || job.user
        fork_push_url = repository.authenticated_push_url(
          GithubClient.for(repository: repository, user: push_user).access_token
        )
        log("[prepare] fork sync: pushing synced #{fork_default} to #{repository.slug}")
        git.run("push", fork_push_url, "HEAD:refs/heads/#{fork_default}", chdir: chdir)
      end

      git.run("checkout", syrus_branch, chdir: chdir)
      begin
        git.run("merge", "--ff-only", fork_default, chdir: chdir)
      rescue GitRunner::GitError
        # Follow-up workflow: syrus branch has prior agent commits that diverge
        # from the upstream merge commit. Keep the branch as-is; the agent
        # continues from the existing tip.
        log("[prepare] fork sync: #{syrus_branch} has existing commits; not fast-forwarding")
      end

      workflow.set_artifact!("fork_sync", {
        "upstream_slug" => upstream.slug,
        "upstream_branch" => upstream_branch,
        "fork_default_branch" => fork_default,
        "synced_at" => Time.current.iso8601,
        "already_up_to_date" => sha_before == sha_after
      })
    end

    def abort_fork_merge(git, chdir)
      git.run("merge", "--abort", chdir: chdir)
    rescue GitRunner::GitError
      nil
    end

    def record_fork_sync_conflict!(upstream, upstream_branch, git_output)
      failure = {
        "upstream_slug" => upstream.slug,
        "upstream_branch" => upstream_branch,
        "git_output" => git_output.to_s.safe_byteslice(0, 4096)
      }
      workflow.set_artifact!("fork_sync_failure", failure)
      log("[prepare] fork sync: merge conflict with upstream #{upstream.slug}@#{upstream_branch}")
    end

    def fork_sync_conflict_message(upstream, upstream_branch)
      <<~MSG.strip
        [fork sync] #{repository.slug} has merge conflicts with upstream #{upstream.slug}@#{upstream_branch}. \
        Manually sync your fork before retrying this Job:
          git fetch upstream #{upstream_branch}
          git checkout #{repository.default_branch}
          git merge upstream/#{upstream_branch}
          git push origin #{repository.default_branch}
      MSG
    end

    def mise_version_file?
      MISE_VERSION_FILES.any? { |f| workspace.path.join(f).exist? }
    end

    def run_mise_install
      log("[prepare] version file detected; running mise install")
      buffer = new_log_buffer
      tail = +""
      result = ProcessRunner.new(
        env: env,
        command: [ "mise", "install" ],
        chdir: workspace.path,
        timeout: MISE_INSTALL_TIMEOUT,
        kind: "prepare",
        run: run,
        workflow: workflow,
        on_output_chunk: ->(chunk) {
          append_output_tail(tail, chunk)
          stream_buffered_chunk(buffer, chunk)
        }
      ).run
      flush_log_buffer(buffer)
      return if result.success? && !result.timed_out

      failure = prepare_failure_payload("mise install", result, tail)
      record_mise_install_soft_failure!(failure)
    end

    def record_mise_install_soft_failure!(failure)
      soft = failure.merge("soft" => true)
      step.update!(details: (step.details || {}).merge("mise_install_failure" => soft))
      workflow.set_artifact!("mise_install_failure", soft)
      log("[prepare] WARNING (mise install, non-fatal): #{prepare_failure_message(failure)}")
    end

    def env
      ProcessRunner.forwarded_env(PREP_ENV_FORWARD, extra: workspace_dependency_env)
    end
  end
end
