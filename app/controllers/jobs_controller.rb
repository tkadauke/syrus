class JobsController < ApplicationController
  before_action :load_job, except: %i[ new create grade_log ]

  def show
    @job_pinned = Current.user.job_pins.exists?(job: @job)
    @tags = Current.user.tags.ordered
    @dependency_target_options = dependency_target_options
    @pending_operator_question = @job.operator_questions
                                     .joins(:run)
                                     .merge(Run.where(state: "awaiting_operator"))
                                     .order(asked_at: :desc, created_at: :desc)
                                     .first
  end

  def new
    @repositories       = Current.user.repositories.active.order(:owner, :name)
    @selected_repository_id = params[:repository_id]
    @configured_agent_providers = Current.user.configured_agent_providers
    @selected_agent_provider = params[:agent_provider].to_s.presence
    @create_more        = create_more?
    @prompt_templates   = PromptTemplate.all
  end

  # Create a direct Job from a free-form operator prompt — no GitHub
  # issue, no cron schedule. Behaves like a cron Job fire: the prompt
  # is pre-rendered at create time and passed to StepDispatcher so
  # the agent receives it verbatim when RunJob starts.
  def create
    @repositories     = Current.user.repositories.active.order(:owner, :name)
    @configured_agent_providers = Current.user.configured_agent_providers
    @prompt_templates = PromptTemplate.all
    @create_more      = create_more?
    @selected_repository_id = params[:repository_id]

    repository = Current.user.repositories.active.find_by(id: params[:repository_id])
    @selected_repository_id = params[:repository_id]
    agent_provider = params[:agent_provider].to_s.presence
    @selected_agent_provider = agent_provider

    unless repository
      flash.now[:alert] = "Repository not found or not active."
      render :new, status: :unprocessable_content
      return
    end

    if agent_provider.present? && !Current.user.agent_provider_configured?(agent_provider)
      flash.now[:alert] = "That agent is not configured."
      render :new, status: :unprocessable_content
      return
    end

    title = params[:title].to_s.strip.presence || "Direct job"
    prompt_text = params[:prompt].to_s.strip

    if prompt_text.blank?
      flash.now[:alert] = "Prompt can't be blank."
      render :new, status: :unprocessable_content
      return
    end

    priority = params[:priority].to_s.presence
    priority = "medium" unless Job::PRIORITIES.include?(priority)

    job = Current.user.jobs.create!(
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: title,
      issue_body: prompt_text,
      agent_provider: agent_provider || repository.effective_agent_provider,
      priority: priority
    )

    attachment_errors = attach_initial_job_attachments(job)
    if attachment_errors.any?
      job.destroy!
      flash.now[:alert] = attachment_errors.to_sentence
      render :new, status: :unprocessable_content
      return
    end

    rendered_prompt = Prompts::DirectJob.new(prompt: prompt_text).to_s
    job.advance_after_triage!
    workflow = Workflows::Initial.instantiate(job: job, agent_provider: job.agent_provider)
    StepDispatcher.start_workflow(workflow, prompt: rendered_prompt)

    if @create_more
      redirect_to new_job_path(repository_id: repository.id, create_more: "1"), notice: "Direct job created."
    else
      redirect_to job_path(job), notice: "Direct job created."
    end
  end

  def start
    unless @job.direct?
      redirect_to job_path(@job), alert: "Only direct Jobs can be started manually."
      return
    end

    if @job.closed?
      redirect_to job_path(@job), alert: "Thread is closed — reopen it before starting work."
      return
    end

    if @job.any_active_run?
      redirect_to job_path(@job), alert: "A Run is already in progress — wait for it to finish."
      return
    end

    if @job.runs.exists?
      redirect_to job_path(@job), alert: "This Job has already been started — use Retry instead."
      return
    end

    workflow = @job.workflows.where(state: "queued", trigger_kind: "initial").order(:created_at).first ||
               Workflows::Initial.instantiate(job: @job, agent_provider: @job.agent_provider)
    rendered_prompt = Prompts::DirectJob.new(prompt: @job.issue_body.to_s).to_s
    StepDispatcher.start_workflow(workflow, prompt: rendered_prompt)

    redirect_to job_path(@job, tab: "workflows"), notice: "Initial workflow enqueued."
  end

  # Retry — push another commit to the existing branch by spawning
  # a new Run on the same Job. Useful when the agent stopped halfway
  # through and you want it to take another swing without abandoning the
  # in-flight work.
  def run_again
    ctx = params[:retry_context].presence || params[:replay_context]
    ctx = ctx.to_s.strip
    artifacts = ctx.present? ? { "replay_context" => ctx } : nil
    agent_provider = params[:agent_provider].to_s.presence

    result = RetryWorkflowEnqueuer.call(
      job: @job,
      artifacts: artifacts,
      agent_provider: agent_provider,
      provider_validation: :retry_alternate
    )
    unless result.success?
      redirect_to job_path(@job), alert: result.error
      return
    end

    notice = agent_provider.present? ? "Retry workflow enqueued with #{agent_provider.titleize}." : "Retry workflow enqueued."
    redirect_to job_path(@job, tab: "workflows"), notice: notice
  end

  # Start over — close this thread (no more polling, no more runs), then
  # open a fresh Job for the same issue. The new Job clones, creates a
  # new branch, and opens a new PR. The old branch + PR are abandoned
  # but left untouched on GitHub.
  def restart
    @job.cancel_active_runs_and_close!("replaced") if @job.open?
    skip_prepare = @job.sync_skip_prepare_from_source!
    new_job = Current.user.jobs.create!(
      repository: @job.repository,
      issue_number: @job.issue_number,
      skip_prepare: skip_prepare,
      operator_chat_disabled: @job.operator_chat_disabled?
    )
    new_job.advance_after_triage!
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
    agent_provider = params[:agent_provider].to_s.presence
    return unless valid_configured_agent_provider?(agent_provider)
    @job.switch_agent_provider!(agent_provider) if agent_provider.present?

    # `manual: true` — bypass the pr_comment / ci_failure cap that
    # exists to defend the autonomous 5-minute poller against
    # runaway loops. The operator clicking the button is an explicit
    # override; without this, the click is a silent no-op once a Job
    # has burned through PR_COMMENT_FOLLOWUP_CAP rounds.
    if agent_provider.present?
      PollPullRequestJob.perform_later(@job.id, manual: true, agent_provider: agent_provider)
    else
      PollPullRequestJob.perform_later(@job.id, manual: true)
    end
    notice = agent_provider.present? ? "Checking PR feedback with #{agent_provider.titleize} now…" : "Checking PR feedback now…"
    redirect_to job_path(@job), notice: notice
  end

  # Continue a failed/cancelled Run by reloading its agent session
  # in a NEW Run. Carries `parent_session_id` so RunJob restores the
  # JSONL to disk before invoking the provider's resume path. The new Run uses
  # Prompts::Resume as its prompt — resume invocations still
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
      redirect_to job_path(@job), alert: "No agent session captured for that Run — try Retry instead."
      return
    end

    workflow = Workflows::Resume.instantiate(job: @job, agent_provider: session.provider)
    # The first (and only) step of Resume is `manual` — pass the
    # parent session id so the provider can resume the captured session.
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
    agent_provider = params[:agent_provider].to_s.presence
    return unless valid_configured_agent_provider?(agent_provider)
    @job.switch_agent_provider!(agent_provider) if agent_provider.present?

    workflow = Workflows::Rebase.instantiate(job: @job, agent_provider: agent_provider)
    StepDispatcher.start_workflow(workflow)
    notice = agent_provider.present? ? "Rebase workflow enqueued with #{agent_provider.titleize}." : "Rebase workflow enqueued."
    redirect_to job_path(@job), notice: notice
  end

  # Stop a single active Run without closing the thread. Useful when
  # a run is clearly stuck. The thread stays open so the operator can
  # retry, resume, or run again after stopping.
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
  #     should use Start over instead — local-only commits are gone)
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
      redirect_to job_path(@job), alert: "Workspace already cleaned up — use Start over."
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
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
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

  def operator_response
    question = @job.operator_questions.includes(:run).find_by(id: params[:operator_question_id])
    unless question
      redirect_to job_path(@job), alert: "Operator question not found."
      return
    end

    text = params[:text].to_s.strip
    if text.blank?
      redirect_to job_path(@job, anchor: "operator-question-#{question.id}"), alert: "Response can't be blank."
      return
    end

    question.record_response!(text: text)
    run = question.run
    run.resume_after_operator_response!(response_text: text) if run.awaiting_operator?

    redirect_to job_path(@job, anchor: "operator-question-#{question.id}"), notice: "Response sent."
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
    unless @job.repository.installation&.active? || Current.user.github_token.present?
      @source_error = "GitHub token not configured. Add one in Settings to browse source."
      return
    end

    github       = GithubClient.for(repository: @job.repository, user: Current.user)
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

  # Enqueue a DiagnoseRunJob for an active Run. Returns immediately;
  # Turbo Stream refresh delivers the RunHealthSnapshot when ready.
  def diagnose
    run = @job.runs.find_by(id: params[:run_id])
    unless run
      redirect_to job_path(@job), alert: "Run not found."
      return
    end

    unless run.queued? || run.running?
      redirect_to job_path(@job), alert: "Diagnose is only available for active runs."
      return
    end

    DiagnoseRunJob.perform_later(run.id)
    redirect_to job_path(@job), notice: "Diagnostic queued — snapshot will appear shortly."
  end

  def grade_log
    @job = Job.find(params[:id])
    unless @job.user == Current.user || Current.user&.admin?
      head :forbidden
      return
    end

    run = @job.runs.find_by(id: params[:run_id])
    unless run&.step&.kind == "grade"
      render plain: "Grade log is not available for this run.", status: :not_found
      return
    end

    contents = WorkflowWorkspace.grade_log_for(run, params[:name].to_s)
    unless contents
      render plain: "Grade log is no longer available. The workflow workspace may have been pruned.", status: :not_found
      return
    end

    send_data contents,
              type: "text/plain; charset=utf-8",
              disposition: "inline",
              filename: "#{params[:name]}.log"
  end

  def add_dependency
    target = find_dependency_target
    unless target
      redirect_to job_path(@job), alert: "Dependency Job not found."
      return
    end

    dependency = @job.dependencies.find_or_initialize_by(depends_on_job: target)
    dependency.source ||= "manual"
    dependency.created_by_user ||= Current.user

    if dependency.save
      redirect_to job_path(@job), notice: "Dependency added."
    else
      redirect_to job_path(@job), alert: dependency.errors.full_messages.to_sentence
    end
  end

  def remove_dependency
    dependency = @job.dependencies.find_by(id: params[:dependency_id])
    unless dependency
      redirect_to job_path(@job), alert: "Dependency not found."
      return
    end

    unless dependency.manual?
      redirect_to job_path(@job), alert: "Parsed dependencies are kept for audit."
      return
    end

    dependency.destroy!
    @job.start_pending_workflows_if_dependencies_satisfied!
    redirect_to job_path(@job), notice: "Dependency removed."
  end

  def override_dependencies
    unless Current.user.admin?
      redirect_to job_path(@job), alert: "Only admins can override dependencies."
      return
    end

    @job.force_run_dependencies!(user: Current.user)
    redirect_to job_path(@job), notice: "Dependency gate overridden."
  end

  def mark_valid
    unless @job.validity_duplicate? || @job.validity_already_implemented?
      redirect_back fallback_location: job_path(@job), alert: "Job is already marked valid."
      return
    end

    @job.mark_valid_and_queue!
    redirect_back fallback_location: job_path(@job), notice: "Job marked valid and re-queued."
  end

  def add_tag
    tag = find_or_create_tag_from_params
    if tag.nil?
      redirect_to job_path(@job), alert: "Tag name can't be blank."
      return
    end

    @job.job_tags.find_or_create_by!(tag: tag)
    redirect_to job_path(@job), notice: "Tag added."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to job_path(@job), alert: e.record.errors.full_messages.to_sentence
  end

  def remove_tag
    tag = Current.user.tags.find_by(id: params[:tag_id])
    unless tag
      redirect_to job_path(@job), alert: "Tag not found."
      return
    end

    @job.job_tags.where(tag: tag).destroy_all
    redirect_to job_path(@job), notice: "Tag removed."
  end

  private

  def create_more?
    ActiveModel::Type::Boolean.new.cast(params[:create_more])
  end

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

  def valid_configured_agent_provider?(agent_provider)
    return true if agent_provider.blank?
    return true if Current.user.agent_provider_configured?(agent_provider)

    redirect_to job_path(@job), alert: "That agent is not configured."
    false
  end

  def find_or_create_tag_from_params
    name = params[:tag_name].to_s.strip
    return nil if name.blank?

    Current.user.tags.find_or_create_by!(name: name) { |tag| tag.color = "gray" }
  end

  def load_job
    @job = Current.user.jobs
                  .includes(
                    :repository,
                    :tags,
                    job_attachments: { file_attachment: :blob },
                    dependencies: [ :created_by_user, depends_on_job: :repository ],
                    dependent_links: [ job: :repository ],
                    runs: [ :job_logs, :run_health_snapshots ]
                  )
                  .find(params[:id])
  end

  def find_dependency_target
    if params[:dependency_target].present?
      find_dependency_target_from_select(params[:dependency_target])
    elsif params[:dependency_job_id].present?
      Current.user.jobs.find_by(id: params[:dependency_job_id])
    elsif params[:dependency_issue_number].present?
      @job.repository.jobs.where(issue_number: params[:dependency_issue_number]).order(:created_at).last
    end
  end

  def find_dependency_target_from_select(value)
    type, first, second = value.to_s.split(":", 3)

    case type
    when "job"
      Current.user.jobs.find_by(id: first)
    when "issue"
      repository = Current.user.repositories.find_by(id: first)
      repository&.jobs&.where(kind: "issue", issue_number: second)&.where.not(id: @job.id)&.order(created_at: :desc, id: :desc)&.first
    end
  end

  def dependency_target_options
    jobs = Current.user.jobs
                       .includes(:repository)
                       .where.not(id: @job.id)
                       .order(created_at: :desc, id: :desc)

    seen_issues = {}
    current_issue_key = @job.issue? && @job.issue_number.present? ? [ @job.repository_id, @job.issue_number ] : nil
    jobs.each_with_object([]) do |job, options|
      if job.issue? && job.issue_number.present?
        issue_key = [ job.repository_id, job.issue_number ]
        next if issue_key == current_issue_key
        next if seen_issues[issue_key]

        seen_issues[issue_key] = true
        options << [ dependency_target_label(job), "issue:#{job.repository_id}:#{job.issue_number}" ]
      else
        options << [ dependency_target_label(job), "job:#{job.id}" ]
      end
    end
  end

  def dependency_target_label(job)
    if job.issue? && job.issue_number.present?
      title = job.issue_title.to_s.strip
      title = " — #{title}" if title.present?
      "#{job.repository.slug} ##{job.issue_number}#{title} (Job ##{job.id})"
    else
      title = job.issue_title.to_s.strip.presence || job.kind.titleize
      "#{job.repository.slug} Job ##{job.id} — #{title}"
    end
  end

  def attach_initial_job_attachments(job)
    errors = []

    Array(params.dig(:job_attachment, :files)).compact_blank.each do |file|
      attachment = job.job_attachments.build(attachment_type: "uploaded_file")
      attachment.file.attach(file)
      errors.concat(attachment.errors.full_messages) unless attachment.save
    end

    google_doc_url = params.dig(:job_attachment, :google_doc_url).to_s.strip
    if google_doc_url.present?
      attachment = job.job_attachments.build(
        attachment_type: "google_doc_link",
        google_doc_url: google_doc_url
      )
      errors.concat(attachment.errors.full_messages) unless attachment.save
    end

    errors
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
