require "fileutils"

# Per-Workflow workspace. One full clone at
# $SYRUS_DATA_ROOT/workflows/<workflow_id>/, lifecycle owned by the
# Workflow's terminal state transitions (not the individual Run).
#
# Cloning depth: we used to fetch with `--depth 50` to keep clones
# small, but the shallow window doesn't reach historical SHAs after
# rebases or force-pushes — stacked-PR checkouts then failed with
# "reference is not a tree". Full clones are slow on a per-Workflow
# basis but correct. The plan is to switch to a shared bare clone
# plus per-Workflow worktrees (one fetch, many cheap checkouts),
# which fixes both the cost and the correctness side. Until then,
# pay the clone cost.
#
# All Steps + Runs in a Workflow share this workspace. That's the
# whole point of the v1 chain: implement commits locally, summarize
# same-workflow session continuations in the same workspace (and finds the prior session's
# JSONL on disk where claude already wrote it, no DB roundtrip),
# pr_open / push run `git push` from the same workspace's HEAD.
#
# Concurrency note: per-Job SQ concurrency means two Workflows on
# the same Job never run simultaneously. The workspace path is
# unique per Workflow id, so two concurrent Workflows on different
# Jobs (or different Workflows on the same Job in sequence) never
# share a path.
class WorkflowWorkspace
  EXCLUDE_ENTRY = ".syrus/".freeze

  attr_reader :path, :branch_name

  def self.data_root
    Pathname.new(ENV["SYRUS_DATA_ROOT"] || File.expand_path("~/.syrus"))
  end

  def self.path_for(workflow)
    data_root.join("workflows", workflow.id.to_s)
  end

  def self.agent_home_for(workflow, provider)
    data_root.join("agent_homes", "jobs", workflow.job_id.to_s, provider.to_s)
  end

  # Read the committed-but-not-pushed diff (three-dot vs default
  # branch) and list of uncommitted files from the workflow's
  # workspace. Returns nil when: workspace doesn't exist, workflow
  # isn't failed with intact workspace, or there are no changes.
  # Errors are swallowed so callers don't need to rescue.
  def self.local_diff_for(workflow)
    path = path_for(workflow)
    return nil unless path.exist? && workflow.failed? && workflow.cleaned_up_at.nil?

    git = GitRunner.new
    default_ref = base_ref_for(workflow.job)
    committed   = git.run("diff", "#{default_ref}...HEAD", chdir: path.to_s).strip
    uncommitted = git.run("status", "--short", chdir: path.to_s).strip

    return nil if committed.empty? && uncommitted.empty?

    { committed: committed, uncommitted: uncommitted }
  rescue StandardError => e
    Rails.logger.warn("[WorkflowWorkspace] local_diff_for failed for workflow ##{workflow.id}: #{e.class}: #{e.message}")
    nil
  end

  def self.grade_log_for(run, name)
    return nil unless run&.workflow
    return nil unless name.to_s.match?(RepoGradePlan::NAME_PATTERN)

    path = path_for(run.workflow).join(".syrus", "grade-output", "iteration-#{run.iteration}", "#{name}.log")
    return path.binread if path.file?

    db_log = run.job_logs.where(kind: "grade_log").order(:sequence).pluck(:chunk).join
    return db_log if db_log.present? || run.running?

    stored_grade_output_for(run, name)
  rescue StandardError => e
    Rails.logger.warn("[WorkflowWorkspace] grade_log_for failed for Run ##{run&.id}: #{e.class}: #{e.message}")
    nil
  end

  def self.stored_grade_output_for(run, name)
    step = run.step
    return nil unless step&.kind == "grader"
    return nil unless step.details.is_a?(Hash)
    return nil unless step.details["name"] == name

    step.details["output"]
  end

  # Class-level cleanup so the Workflow's AASM terminal-transition
  # callback can fire it without instantiating the full workspace.
  # Best-effort: if the path is gone or unreadable, swallow. Stamps
  # `cleaned_up_at` on the Workflow so the UI ("Retry from failed
  # step" button) and WorkflowWorkspacePruneJob can tell the
  # workspace is no longer on disk. Stamped even when the dir was
  # already gone — the state we care about is "not on disk", not
  # "we did the rm_rf."
  #
  # IMPORTANT: `cleaned_up_at` is only set when the directory is
  # confirmed absent after the rm_rf. If rm_rf silently fails to
  # remove the directory (e.g. permissions), we log a warning and
  # leave `cleaned_up_at` nil so WorkflowWorkspacePruneJob retries
  # rather than treating a still-present dir as already gone.
  # A workspace lives on the local disk of the worker that ran the workflow.
  # Skip cleaning it here ONLY when another *live* worker pod owns it — under
  # local-disk multi-worker its disk is unreachable from here, and cleaning
  # would falsely stamp cleaned_up_at while the real workspace persists on the
  # owning pod. Everything else is cleanable here:
  #   - no recorded host (legacy / not stamped),
  #   - it ran on this host,
  #   - the recorded host is not a live worker (single-host Docker where the
  #     container was recreated with a new hostname but the shared volume — and
  #     the workspace — persist; or a dead pod whose disk is already gone).
  def self.cleanable_here?(workflow)
    host = workflow.worker_hostname
    return true if host.blank? || host == SyrusVersion.hostname

    !InstanceVersion.worker_live?(host)
  end

  def self.cleanup_for(workflow)
    unless cleanable_here?(workflow)
      Rails.logger.debug("[WorkflowWorkspace] skip cleanup for Workflow ##{workflow.id}: ran on #{workflow.worker_hostname}, not #{SyrusVersion.hostname}")
      return
    end

    p = path_for(workflow)
    agent_home = data_root.join("agent_homes", "jobs", workflow.job_id.to_s)
    Rails.logger.info("[WorkflowWorkspace] cleanup start for Workflow ##{workflow.id} at #{p}")

    FileUtils.rm_rf(p.to_s) if p.exist?
    FileUtils.rm_rf(agent_home.to_s) if agent_home.exist?

    if p.exist?
      Rails.logger.warn("[WorkflowWorkspace] rm_rf completed but #{p} still present for Workflow ##{workflow.id} — will retry on next prune pass")
      return
    end

    workflow.update_columns(cleaned_up_at: Time.current) if workflow.persisted?
    Rails.logger.info("[WorkflowWorkspace] cleanup done for Workflow ##{workflow.id}")
  rescue StandardError => e
    Rails.logger.warn("[WorkflowWorkspace] cleanup failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
  end

  def initialize(workflow, git: nil)
    @workflow = workflow
    @job = workflow.job
    @repository = @job.repository
    @git = git || GitRunner.new
    @path = self.class.path_for(workflow)
    @branch_name = @job.branch_name.presence || initial_branch_name
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  # Idempotent. The first Run on the first Step pays the clone cost;
  # subsequent Runs across the rest of the Workflow's chain find the
  # workspace already there and either no-op (clean working tree) or
  # restore-to-clean (retry-within-step after a crashed prior Run).
  #
  # Restore semantics on retry: committed work survives, uncommitted
  # edits don't.
  #
  # Fresh-clone path sweeps all sibling workflows' workspaces before
  # cloning. Per-Job SQ concurrency guarantees the siblings are terminal
  # so no live workspace is touched. This caps disk at one workspace
  # per Job — the largest contributor to PVC fill on wedged stacks.
  def setup
    if path.exist?
      ensure_exclude_entry
      ensure_clean_working_tree
    else
      sweep_sibling_workspaces!
      clone_and_checkout
      ensure_exclude_entry
    end
    configure_git_author
  end

  def cleanup
    self.class.cleanup_for(@workflow)
  end

  # The git ref for this Job's base branch inside the workspace. For fork→
  # upstream Jobs it's the fetched upstream tip (`upstream/<default>`);
  # otherwise the fork's own `origin/<default>`. Used for branch creation and
  # for the three-dot diff base.
  def base_ref
    self.class.base_ref_for(@job, workflow: @workflow)
  end

  # SHA/ref-agnostic form usable without an instance (class method used by
  # local_diff_for on a failed workflow's on-disk workspace).
  def self.base_ref_for(job, workflow: nil)
    prepared_base = workflow&.artifact(RebaseTarget::BASE_BRANCH_ARTIFACT).presence
    return "origin/#{prepared_base}" if prepared_base.present?

    if job.base_on_upstream_default?
      "upstream/#{job.base_default_branch}"
    else
      "origin/#{job.repository.default_branch}"
    end
  end

  private

  # Delete every other terminal workflow's workspace on this Job before
  # cloning a fresh one. Per-Job SQ concurrency ensures nothing else is
  # running, so all siblings are guaranteed to be terminal. Stamping
  # cleaned_up_at on each sibling lets retry_available? return false for
  # them immediately, preventing stale "Retry from failed step" buttons.
  def sweep_sibling_workspaces!
    @job.workflows.where.not(id: @workflow.id).find_each do |sibling|
      next unless sibling.terminal?
      Rails.logger.info("[WorkflowWorkspace] eager sweep of sibling Workflow ##{sibling.id} for Job ##{@job.id}")
      self.class.cleanup_for(sibling)
    end
  rescue StandardError => e
    Rails.logger.warn("[WorkflowWorkspace] sweep_sibling_workspaces! failed for Job ##{@job.id}: #{e.class}: #{e.message}")
  end

  def initial_branch_name
    if @job.cron?
      "syrus/scheduled-#{@job.scheduled_task_id}-#{@job.id}"
    elsif local_source_path
      "syrus/local-#{@job.id}"
    elsif @job.direct?
      "syrus/direct-#{@job.id}"
    elsif @job.main_grader?
      @repository.default_branch
    else
      "syrus/issue-#{@job.issue_number}-#{@job.id}"
    end
  end

  def local_source_path
    @workflow.artifact("local_source_path").presence
  end

  # Use the authenticated URL for clone + ls-remote + fetch (the
  # only operations that talk to origin). Scrub the persisted
  # `origin` URL after clone so the token doesn't sit in
  # .git/config indefinitely; subsequent operations pass the
  # authenticated URL transiently in argv (same pattern push uses).
  def authenticated_url
    @repository.authenticated_url(user: @job.user)
  end

  def clone_and_checkout
    FileUtils.mkdir_p(path.dirname)
    if local_source_path
      clone_local_source
      return
    end

    @git.run(
      "clone",
      "--branch", clone_checkout_branch,
      "--no-tags", authenticated_url, path.to_s,
      env: @env
    )

    @git.run("remote", "set-url", "origin", @repository.remote_url, chdir: path.to_s)

    if @job.main_grader?
      checkout_main_sha!
      return
    end

    # Fork → upstream: fetch the in-instance upstream's default branch so the
    # work branch bases off (and diffs against) the upstream, not the fork.
    fetch_upstream_base! if base_on_upstream_default?

    # Check whether the target branch already exists on origin
    # (follow-up Workflows on a Job that already has a branch from
    # a prior Initial). Use the authenticated URL — ls-remote
    # against origin's name would fall back to anonymous after
    # the scrub below.
    remote_ref = @git.run(
      "ls-remote", "--heads", authenticated_url,
      "refs/heads/#{@branch_name}",
      chdir: path.to_s, env: @env
    )

    if remote_ref.strip.present?
      @git.run(
        "fetch", authenticated_url,
        "refs/heads/#{@branch_name}:refs/heads/#{@branch_name}",
        chdir: path.to_s, env: @env
      )
      @git.run("checkout", @branch_name, chdir: path.to_s)
    elsif base_on_upstream_default?
      # New branch based on the upstream's default tip, not the fork's default.
      @git.run("checkout", "-b", @branch_name, base_ref, chdir: path.to_s)
    else
      @git.run("checkout", "-b", @branch_name, chdir: path.to_s)
    end

    checkout_main_sha!
  end

  # For main_grader workflows: detach HEAD at the exact SHA that was
  # polled so graders run against a reproducible snapshot regardless
  # of what lands on main between clone and execution.
  def checkout_main_sha!
    return unless @job.main_grader?

    sha = @workflow.artifact("main_sha")
    return if sha.blank?

    @git.run("checkout", sha, chdir: path.to_s)
  end

  def base_branch
    @base_branch ||= RebaseTarget.branch_for(job: @job, workflow: @workflow)
  end

  def base_on_upstream_default?
    @job.base_on_upstream_default?
  end

  # Branch checked out from origin (the fork) at clone time. For fork→upstream
  # jobs the work branch is re-based off the upstream tip afterwards, so clone
  # the fork's own default here (guaranteed to exist even when it differs from
  # the upstream's default branch name).
  def clone_checkout_branch
    return @repository.default_branch if base_on_upstream_default?

    base_branch
  end

  # Fetch the in-instance upstream's default branch into a remote-tracking ref
  # (`upstream/<default>`) so the work branch bases off it and diffs reference
  # it. Anonymous fetch — private-upstream credentials are intentionally out of
  # scope for now.
  def fetch_upstream_base!
    upstream = @job.base_repository
    branch = upstream.default_branch
    @git.run("remote", "add", "upstream", upstream.remote_url, chdir: path.to_s)
    @git.run(
      "fetch", "--no-tags", "upstream",
      "+refs/heads/#{branch}:refs/remotes/upstream/#{branch}",
      chdir: path.to_s, env: @env
    )
  end

  def clone_local_source
    source = Pathname.new(local_source_path).expand_path
    raise "local source path does not exist: #{source}" unless source.exist?

    @git.run(
      "clone",
      "--branch", @repository.default_branch,
      "--no-tags", source.to_s, path.to_s,
      env: @env
    )
    @git.run("checkout", "-b", @branch_name, chdir: path.to_s)
  end

  # Workspace exists from a prior Run, typically a retry-within-step
  # after a crash. The working tree may be dirty (uncommitted edits
  # the prior agent had in flight). Restore tracked files to HEAD
  # and remove untracked ones so the new Run sees a known starting
  # point. Committed work survives.
  def ensure_clean_working_tree
    status = @git.run("status", "--porcelain", chdir: path.to_s)
    return if status.strip.empty?
    # `git restore .` errors when there are no tracked-modified
    # paths (e.g. dirt is purely untracked files). Tolerate that —
    # `git clean` handles untracked.
    begin
      @git.run("restore", ".", chdir: path.to_s)
    rescue GitRunner::GitError
      nil
    end
    @git.run("clean", "-fd", chdir: path.to_s)
  end

  def configure_git_author
    @git.configure_author(BotIdentity.for(@job), chdir: path.to_s)
  end

  def ensure_exclude_entry
    GitInfoExclude.ensure_entry!(path, EXCLUDE_ENTRY)
  end
end
