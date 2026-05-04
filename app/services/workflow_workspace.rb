require "fileutils"

# Per-Workflow workspace. One shallow clone at
# $SYRUS_DATA_ROOT/workflows/<workflow_id>/, lifecycle owned by the
# Workflow's terminal state transitions (not the individual Run).
#
# All Steps + Runs in a Workflow share this workspace. That's the
# whole point of the v1 chain: implement commits locally, summarize
# `--resume`s in the same workspace (and finds the prior session's
# JSONL on disk where claude already wrote it, no DB roundtrip),
# pr_open / push run `git push` from the same workspace's HEAD.
#
# Concurrency note: per-Job SQ concurrency means two Workflows on
# the same Job never run simultaneously. The workspace path is
# unique per Workflow id, so two concurrent Workflows on different
# Jobs (or different Workflows on the same Job in sequence) never
# share a path.
class WorkflowWorkspace
  CLONE_DEPTH = 50

  attr_reader :path, :branch_name

  def self.data_root
    Pathname.new(ENV["SYRUS_DATA_ROOT"] || File.expand_path("~/.syrus"))
  end

  def self.path_for(workflow)
    data_root.join("workflows", workflow.id.to_s)
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
    default_branch = workflow.job.repository.default_branch
    committed   = git.run("diff", "#{default_branch}...HEAD", chdir: path.to_s).strip
    uncommitted = git.run("status", "--short", chdir: path.to_s).strip

    return nil if committed.empty? && uncommitted.empty?

    { committed: committed, uncommitted: uncommitted }
  rescue StandardError => e
    Rails.logger.warn("[WorkflowWorkspace] local_diff_for failed for workflow ##{workflow.id}: #{e.class}: #{e.message}")
    nil
  end

  # Class-level cleanup so the Workflow's AASM terminal-transition
  # callback can fire it without instantiating the full workspace.
  # Best-effort: if the path is gone or unreadable, swallow. Stamps
  # `cleaned_up_at` on the Workflow so the UI ("Retry from failed
  # step" button) and WorkflowWorkspacePruneJob can tell the
  # workspace is no longer on disk. Stamped even when the dir was
  # already gone — the state we care about is "not on disk", not
  # "we did the rm_rf."
  def self.cleanup_for(workflow)
    p = path_for(workflow)
    FileUtils.rm_rf(p.to_s) if File.exist?(p.to_s)
    workflow.update_columns(cleaned_up_at: Time.current) if workflow.persisted?
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
  # edits don't. Same contract as Resume Runs today.
  def setup
    if path.exist?
      ensure_clean_working_tree
    else
      clone_and_checkout
    end
  end

  def cleanup
    self.class.cleanup_for(@workflow)
  end

  private

  def initial_branch_name
    if @job.cron?
      "syrus/scheduled-#{@job.scheduled_task_id}-#{@job.id}"
    else
      "syrus/issue-#{@job.issue_number}-#{@job.id}"
    end
  end

  # Use the authenticated URL for clone + ls-remote + fetch (the
  # only operations that talk to origin). Scrub the persisted
  # `origin` URL after clone so the token doesn't sit in
  # .git/config indefinitely; subsequent operations pass the
  # authenticated URL transiently in argv (same pattern push uses).
  def authenticated_url
    @repository.authenticated_push_url(@job.user.github_token)
  end

  def clone_and_checkout
    FileUtils.mkdir_p(path.dirname)
    @git.run(
      "clone", "--depth", CLONE_DEPTH.to_s,
      "--branch", @repository.default_branch,
      "--no-tags", authenticated_url, path.to_s,
      env: @env
    )

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

    @git.run("remote", "set-url", "origin", @repository.remote_url, chdir: path.to_s)

    if remote_ref.strip.present?
      @git.run(
        "fetch", "--depth", CLONE_DEPTH.to_s, authenticated_url,
        "refs/heads/#{@branch_name}:refs/heads/#{@branch_name}",
        chdir: path.to_s, env: @env
      )
      @git.run("checkout", @branch_name, chdir: path.to_s)
    else
      @git.run("checkout", "-b", @branch_name, chdir: path.to_s)
    end
  end

  # Workspace exists from a prior Run, typically a retry-within-step
  # after a crash. The working tree may be dirty (uncommitted edits
  # the prior agent had in flight). Restore tracked files to HEAD
  # and remove untracked ones so the new Run sees a known starting
  # point. Committed work survives — same contract as Resume Runs.
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
end
