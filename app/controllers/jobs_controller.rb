class JobsController < ApplicationController
  before_action :load_job, except: %i[ new create ]

  def show
  end

  def new
    @repositories = Current.user.repositories.active.order(:owner, :name)
    @selected_repository_id = params[:repository_id]
  end

  # Create an ad hoc Job from a free-form operator prompt — no GitHub
  # issue, no cron schedule. Behaves like a cron Job fire: the prompt
  # is pre-rendered at create time and passed to StepDispatcher so
  # the agent receives it verbatim when RunJob starts.
  def create
    @repositories = Current.user.repositories.active.order(:owner, :name)

    repository = Current.user.repositories.active.find_by(id: params[:repository_id])
    unless repository
      flash.now[:alert] = "Repository not found or not active."
      render :new, status: :unprocessable_entity
      return
    end

    title = params[:title].to_s.strip.presence || "Ad hoc job"
    prompt_text = params[:prompt].to_s.strip

    if prompt_text.blank?
      @selected_repository_id = params[:repository_id]
      flash.now[:alert] = "Prompt can't be blank."
      render :new, status: :unprocessable_entity
      return
    end

    job = Current.user.jobs.create!(
      repository: repository,
      kind: "adhoc",
      issue_number: nil,
      issue_title: title,
      issue_body: prompt_text
    )

    rendered_prompt = Prompts::AdhocJob.new(prompt: prompt_text).to_s
    workflow = Workflows::Initial.instantiate(job: job)
    StepDispatcher.start_workflow(workflow, prompt: rendered_prompt)

    redirect_to job_path(job), notice: "Ad hoc job created."
  end

  # Soft replay — push another commit to the existing branch by spawning
  # a new Run on the same Job. Useful when the agent stopped halfway
  # through and you want it to take another swing without abandoning the
  # in-flight work.
  def run_again
    if @job.closed?
      redirect_to job_path(@job), alert: "Thread is closed — use Start over to begin a new one."
      return
    end

    if @job.any_active_run?
      redirect_to job_path(@job), alert: "A Run is already in progress — wait for it to finish."
      return
    end

    ctx = params[:replay_context].to_s.strip
    artifacts = ctx.present? ? { "replay_context" => ctx } : nil
    workflow = Workflows::Replay.instantiate(job: @job, artifacts: artifacts)
    StepDispatcher.start_workflow(workflow)
    redirect_to job_path(@job, tab: "workflows"), notice: "Replay workflow enqueued."
  end

  # Hard reset — close this thread (no more polling, no more runs), then
  # open a fresh Job for the same issue. The new Job clones, creates a
  # new branch, and opens a new PR. The old branch + PR are abandoned
  # but left untouched on GitHub.
  def restart
    @job.cancel_active_runs_and_close!("replaced") if @job.open?
    new_job = Current.user.jobs.create!(
      repository: @job.repository,
      issue_number: @job.issue_number
    )
    redirect_to job_path(new_job), notice: "Started over — new branch and PR will be created."
  end

  def cancel
    if @job.closed?
      redirect_to job_path(@job), alert: "Job is already closed."
      return
    end

    @job.cancel_active_runs_and_close!("cancelled")
    redirect_to job_path(@job), notice: "Cancellation requested."
  end

  # Manually fire PollPullRequestJob for this Job — useful when the
  # operator just left a review comment and doesn't want to wait for
  # the 5-min recurring schedule.
  def poll_feedback
    unless @job.open? && @job.pr_number.present?
      redirect_to job_path(@job), alert: "Can only check feedback on open Jobs that have a PR."
      return
    end

    PollPullRequestJob.perform_later(@job.id)
    redirect_to job_path(@job), notice: "Checking PR feedback now…"
  end

  # Continue a failed/cancelled Run by reloading its claude session
  # in a NEW Run. Carries `parent_session_id` so RunJob restores the
  # JSONL to disk before invoking `claude --resume`. The new Run uses
  # Prompts::Resume as its prompt — claude --print --resume still
  # needs an arg, and silent re-invocation with the original prompt
  # would confuse the model.
  def resume
    source_run = @job.runs.find_by(id: params[:source_run_id])
    unless source_run
      redirect_to job_path(@job), alert: "Source Run not found."
      return
    end
    unless %w[failed cancelled].include?(source_run.state)
      redirect_to job_path(@job), alert: "Only failed or cancelled Runs are resumable."
      return
    end
    session = source_run.claude_session
    unless session
      redirect_to job_path(@job), alert: "No Claude session captured for that Run — try Replay instead."
      return
    end

    workflow = Workflows::Resume.instantiate(job: @job)
    # The first (and only) step of Resume is `manual` — pass the
    # parent session id so AgentInvocation runs claude with
    # `--resume <session>`.
    StepDispatcher.start_workflow(workflow, parent_session_id: session.session_id)
    redirect_to job_path(@job), notice: "Resume workflow enqueued."
  end

  # Manually trigger PollRebaseJob for this Job — same poller that
  # runs every 15min, just operator-initiated when they don't want
  # to wait. Persists pr_mergeable + checked_at on the Job (and
  # broadcasts a refresh to morph the badge in place).
  def check_mergeability
    unless @job.pr_number.present? || @job.external_pr_number.present?
      redirect_to job_path(@job), alert: "No PR on this Job to check."
      return
    end

    PollRebaseJob.perform_later(@job.id, bypass_cache: true)
    redirect_to job_path(@job), notice: "Checking mergeability now…"
  end

  # Manually enqueue a rebase Run on this Job's PR. Same trigger the
  # auto-rebase poller uses, just operator-initiated when they don't
  # want to wait for the next 15-min sweep. Refuses to stack rebases
  # or rebase a Job with no PR. Skips the closed-Job guard since rebase
  # Runs are independent of Job lifecycle (preempted Job's external PR
  # can still need rebases).
  def rebase
    unless @job.pr_number.present? || @job.external_pr_number.present?
      redirect_to job_path(@job), alert: "No PR on this Job to rebase."
      return
    end

    if @job.workflows.active.where(trigger_kind: "rebase").exists?
      redirect_to job_path(@job), alert: "A rebase is already in progress — wait for it to finish."
      return
    end

    workflow = Workflows::Rebase.instantiate(job: @job)
    StepDispatcher.start_workflow(workflow)
    redirect_to job_path(@job), notice: "Rebase workflow enqueued."
  end

  # Stop a single active Run without closing the thread. Useful when
  # a run is clearly stuck. The thread stays open so the operator can
  # replay, resume, or run again after stopping.
  def stop_run
    run = @job.runs.find_by(id: params[:run_id])
    unless run
      redirect_to job_path(@job), alert: "Run not found."
      return
    end

    unless run.may_cancel?
      redirect_to job_path(@job), alert: "Run is not active."
      return
    end

    run.cancel!
    run.save!
    redirect_to job_path(@job), notice: "Run stopped."
  end

  # Retry the failed step in a failed Workflow without losing the
  # prior succeeded steps' state. Reopens Workflow + Step, creates
  # a new Run on the failed Step. The inline-chain dispatch in
  # RunJob.perform takes the new Run from there. Workspace is NOT
  # re-cloned — we trust the on-disk state (this is precisely why
  # the workspace cleanup was deferred on Workflow.fail).
  #
  # Refused when:
  #   - the Workflow isn't `failed`
  #   - WorkflowWorkspace.cleanup_for has already run (operator
  #     should use Replay instead — local-only commits are gone)
  #   - no failed Step found (one-failed-step-per-workflow holds in
  #     v1; defensive guard for unexpected states)
  def retry_step
    workflow = @job.workflows.find_by(id: params[:workflow_id])
    unless workflow
      redirect_to job_path(@job), alert: "Workflow not found."
      return
    end
    unless workflow.failed?
      redirect_to job_path(@job), alert: "Workflow is not in a failed state."
      return
    end
    unless workflow.retry_available?
      redirect_to job_path(@job), alert: "Workspace already cleaned up — use Replay to start over."
      return
    end

    failed_step = workflow.steps.where(state: "failed").order(:position).first
    unless failed_step
      redirect_to job_path(@job), alert: "No failed step to retry."
      return
    end

    workflow.reopen!
    workflow.save!
    failed_step.reopen!
    failed_step.save!

    failed_step.runs.create!(
      job: @job,
      trigger_kind: workflow.trigger_kind
    )

    redirect_to job_path(@job),
                notice: "Retrying #{failed_step.kind} for workflow ##{workflow.id}…"
  end

  # Push committed (and stage+commit any uncommitted) changes from a
  # failed Workflow's workspace to GitHub. The operator can then open
  # a PR by hand. Refuses when the workspace is gone or the workflow
  # isn't failed. Idempotent: the job no-ops if already pushed.
  def push_commits
    workflow = @job.workflows.find_by(id: params[:workflow_id])
    unless workflow
      redirect_to job_path(@job), alert: "Workflow not found."
      return
    end
    unless workflow.failed? && workflow.cleaned_up_at.nil?
      redirect_to job_path(@job), alert: "Workspace is not available for this workflow."
      return
    end

    PushPendingCommitsJob.perform_later(workflow.id)
    redirect_to job_path(@job), notice: "Pushing commits to GitHub…"
  end

  # Undo a close. The next poll cycle may immediately re-close the
  # Job if the underlying reason still applies (e.g. syrus-stop label
  # still on the PR, PR merged on GitHub) — that's intentional. Local
  # state catches up to GitHub state via the next poll.
  def reopen
    unless @job.may_reopen?
      redirect_to job_path(@job), alert: "Job isn't closed."
      return
    end

    prior_reason = @job.closure_reason
    @job.reopen!
    @job.save!
    redirect_to job_path(@job), notice: reopen_notice(prior_reason)
  end

  # Browse the repository source at a selected commit ref. Defaults to the
  # merge base (the state of the repo before any Syrus commits) when the
  # branch has no ahead commits, or to the most recent branch commit when it
  # does. `?ref=SHA` selects a specific commit; `?path=file/path` loads the
  # content of that file.
  #
  # Rendered inside a lazy Turbo Frame on the Job show page — the GitHub API
  # is only hit when the Source tab is first activated.
  def source
    unless Current.user.github_token.present?
      @source_error = "GitHub token not configured. Add one in Settings to browse source."
      return
    end

    github       = GithubClient.for(Current.user)
    repo_slug    = @job.repository.slug
    default_ref  = @job.repository.default_branch
    branch       = @job.branch_name

    @branch_commits  = []
    @merge_base_sha  = nil

    if branch.present?
      compare = github.compare_commits(repo_slug, default_ref, branch)
      @branch_commits = compare[:commits]
      @merge_base_sha = compare[:merge_base_sha]
    end

    # Default: show the most recent branch commit, or the merge base if the
    # branch has no ahead commits, or the default branch name if we have no
    # branch at all.
    @selected_ref = params[:ref].presence ||
                    @branch_commits.first&.fetch(:sha) ||
                    @merge_base_sha ||
                    default_ref

    begin
      tree_result  = github.file_tree_at(repo_slug, @selected_ref)
      @tree_items  = tree_result[:items]
      @tree_truncated = tree_result[:truncated]
      @file_tree   = build_file_tree(@tree_items)
    rescue => e
      @source_error = "Could not load file tree: #{e.message}"
      @tree_items   = []
      @file_tree    = {}
    end

    @selected_path = params[:path].presence
    if @selected_path && @source_error.nil?
      begin
        @file_content = github.file_content_at(repo_slug, @selected_path, @selected_ref)
      rescue => e
        @file_content_error = e.message
      end
    end
  end

  private

  def reopen_notice(prior_reason)
    base = "Thread reopened."
    case prior_reason
    when "syrus_stop"
      "#{base} Heads up: the next poll will re-close it if the syrus-stop label is still on the PR."
    when "pr_merged", "pr_closed"
      "#{base} Heads up: the next poll will check the PR state and may re-close it."
    else
      base
    end
  end

  def load_job
    @job = Current.user.jobs.includes(:repository, runs: :job_logs).find(params[:id])
  end

  # Converts a flat list of {path:, size:} items into a nested hash
  # suitable for the _source_tree partial. Each node is a hash whose
  # string keys are subdirectory names and whose :files key holds the
  # array of blob items at that level.
  #
  #   build_file_tree([{path:"lib/foo.rb"},{path:"lib/bar/baz.rb"}])
  #   # => {"lib"=>{files:[{path:"lib/foo.rb"}], "bar"=>{files:[...]}}}
  def build_file_tree(items)
    root = { files: [] }
    items.each do |item|
      parts = item[:path].split("/")
      node  = root
      parts[0..-2].each do |dir|
        node[dir] ||= { files: [] }
        node = node[dir]
      end
      node[:files] << item
    end
    root
  end
end
