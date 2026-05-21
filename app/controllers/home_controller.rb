class HomeController < ApplicationController
  PER_PAGE = 25
  DASHBOARD_SUBJECTS = %w[job epic workflow].freeze
  DASHBOARD_VIEWS = %w[list kanban].freeze
  DEFAULT_DASHBOARD_SUBJECT = "epic"
  DEFAULT_DASHBOARD_VIEW = "list"
  KANBAN_PER_PAGE = 100
  JOB_KANBAN_LANES = [
    { key: "queued", title: "Queued" },
    { key: "running", title: "Running" },
    { key: "succeeded", title: "Succeeded" },
    { key: "failed", title: "Failed" }
  ].freeze
  WORKFLOW_KANBAN_COLUMNS = %w[queued running done].freeze
  WORKFLOW_DONE_STATES = %w[succeeded failed cancelled].freeze

  before_action :persist_dashboard_preferences_from_params, only: %i[index epics jobs workflows]

  def index
    @dashboard_subject = dashboard_subject
    @dashboard_view = dashboard_view

    case [ @dashboard_subject, @dashboard_view ]
    when [ "job", "list" ], [ "job", "kanban" ]
      jobs
    when [ "workflow", "list" ], [ "workflow", "kanban" ]
      workflows
    when [ "epic", "kanban" ]
      epics
    else
      epic_list
    end
  end

  def epics
    @active_tab = "epics"
    set_dashboard_view
    load_epics_dashboard
    render :index
  end

  def jobs
    @active_tab = "jobs"
    set_dashboard_view
    load_dashboard
    render :index
  end

  def workflows
    @active_tab = "workflows"
    set_dashboard_view
    load_workflows_dashboard
    render :index
  end

  def update_epic_auto_approval
    epic = Current.user.epics.find(params[:id])
    epic.update!(params.expect(epic: [ :auto_approve_mode ]))
    redirect_back fallback_location: dashboard_epics_path, notice: "Epic auto-approval updated."
  end

  def update_preferences
    subject = params.require(:subject)

    if params.key?(:sort_column) || params.key?(:sort_direction)
      Current.user.update_dashboard_sort!(
        subject: subject,
        column: params.require(:sort_column),
        direction: params.require(:sort_direction)
      )
    end

    if params.key?(:visible_columns)
      Current.user.update_dashboard_columns!(
        subject: subject,
        columns: params[:visible_columns]
      )
    end

    respond_to do |format|
      format.turbo_stream { head :ok }
      format.html do
        redirect_back fallback_location: dashboard_path, notice: "Dashboard preferences updated."
      end
    end
  rescue ActionController::ParameterMissing, ArgumentError => e
    respond_to do |format|
      format.turbo_stream { render plain: e.message, status: :unprocessable_content }
      format.html { redirect_back fallback_location: dashboard_path, alert: e.message }
    end
  end

  def bulk_jobs
    job_ids = Array(params[:job_ids]).filter_map { |id| Integer(id, exception: false) }.uniq
    if job_ids.empty?
      redirect_back fallback_location: dashboard_jobs_path, alert: "Select at least one job."
      return
    end

    jobs = Current.user.jobs.joins(:repository)
                       .where(repositories: { archived_at: nil })
                       .where(id: job_ids)
                       .includes(:runs, :workflows)

    case params[:bulk_action].to_s
    when "retry"
      bulk_retry_jobs(jobs)
    when /\Aretry:(.+)\z/
      bulk_retry_jobs(jobs, agent_provider: Regexp.last_match(1))
    when "close"
      bulk_close_jobs(jobs)
    when "approve"
      bulk_approve_jobs(jobs)
    when "review_approve"
      bulk_review_approval(jobs)
    when "commit_review_approval"
      bulk_commit_review_approval(jobs)
    when "apply_tag"
      bulk_apply_tag(jobs)
    else
      redirect_back fallback_location: dashboard_jobs_path, alert: "Choose a bulk action."
    end
  end

  def toggle_landing_pause
    Current.user.update!(landing_paused: !Current.user.landing_paused?)
    LandingQueueProcessorJob.perform_later unless Current.user.landing_paused?
    redirect_back fallback_location: dashboard_jobs_path, notice: Current.user.landing_paused? ? "Landing paused." : "Landing resumed."
  end

  private

  def persist_dashboard_preferences_from_params
    return unless Current.user
    return unless params.key?(:subject) || params.key?(:view)

    Current.user.update_dashboard_preferences!(
      subject: params[:subject].presence,
      view: params[:view].presence
    )
  end

  def dashboard_subject
    normalized_dashboard_param(:subject, DASHBOARD_SUBJECTS) ||
      persisted_dashboard_subject ||
      DEFAULT_DASHBOARD_SUBJECT
  end

  def dashboard_view
    normalized_dashboard_param(:view, DASHBOARD_VIEWS) ||
      persisted_dashboard_view ||
      DEFAULT_DASHBOARD_VIEW
  end

  def normalized_dashboard_param(key, valid_values)
    return unless params.key?(key)

    params[key].to_s.presence_in(valid_values) || default_dashboard_value_for(key)
  end

  def default_dashboard_value_for(key)
    case key.to_sym
    when :subject
      DEFAULT_DASHBOARD_SUBJECT
    when :view
      DEFAULT_DASHBOARD_VIEW
    end
  end

  def persisted_dashboard_subject
    Current.user.dashboard_preferences["last_subject"].to_s.presence_in(DASHBOARD_SUBJECTS)
  end

  def persisted_dashboard_view
    Current.user.dashboard_preferences["last_view"].to_s.presence_in(DASHBOARD_VIEWS)
  end

  def epic_list
    @active_tab = "epics"
    @dashboard_subject = "epic"
    @dashboard_view = "list"
    load_epic_list_dashboard
    render :index
  end

  def load_epic_list_dashboard
    SmartFolder.ensure_builtins!
    SmartFolder.ensure_epic_builtins!
    @page = [ params[:page].to_i, 1 ].max
    @smart_folder = epic_list_smart_folder_from_params
    @filter = ::Epics::Filter.from_params(params, smart_folder: @smart_folder, user: Current.user)
    @schema = ::Filters::Schema.for(subject: :epic, user: Current.user)
    @smart_folders = SmartFolder.for_subject(:epic).where(user: Current.user).order(:position, :id)
    @builtin_smart_folders = SmartFolder.for_subject(:epic).built_in_sidebar_order
    @smart_folder_counts = epic_list_smart_folder_counts(Current.user.epics)
    @primary_builtin_smart_folders, @more_builtin_smart_folders = split_epic_list_builtin_smart_folders

    @epics = @filter.apply(Current.user.epics.includes(:repository))
    @epics_total = @epics.count
    @epics_matching_count = @epics_total
    # Inactive-tab badge shows the unfiltered total, not the active
    # tab's filter applied to the other subject — that path produced
    # arbitrary numbers (rescue-to-total when chips don't exist for
    # the other subject, 0 when a shared chip name compiles cleanly
    # but matches nothing). Total is stable across tabs.
    @jobs_matching_count = jobs_total_for_dashboard
    @workflows_matching_count = workflows_total_for_dashboard
    @epics = @epics.order(updated_at: :desc, id: :desc).offset((@page - 1) * EpicsController::PER_PAGE).limit(EpicsController::PER_PAGE)
  end

  def set_dashboard_view
    @dashboard_subject = case @active_tab
    when "epics" then "epic"
    when "workflows" then "workflow"
    else "job"
    end
    @dashboard_view = params[:view].to_s.presence_in(%w[list kanban]) || (@dashboard_subject == "epic" ? "kanban" : "list")
  end

  def load_epics_dashboard
    active_repo_ids = Current.user.repositories.active.select(:id)
    @page = [ params[:page].to_i, 1 ].max
    SmartFolder.ensure_builtins!
    SmartFolder.ensure_epic_builtins!
    @schema = ::Filters::Schema.for(subject: :epic, user: Current.user)
    @smart_folder = epic_smart_folder_from_params
    @filter = ::Epics::Filter.from_params(params, smart_folder: @smart_folder, user: Current.user)
    @smart_folders = SmartFolder.for_subject(:epic).where(user: Current.user).order(:position, :id)
    @builtin_smart_folders = SmartFolder.for_subject(:epic).built_in_sidebar_order
    @smart_folder_counts = epic_smart_folder_counts(Current.user.epics.where(repository_id: active_repo_ids))
    @primary_builtin_smart_folders, @more_builtin_smart_folders = split_epic_builtin_smart_folders

    @epics = @filter.apply(Current.user.epics.includes(:repository).where(repository_id: active_repo_ids))
    @epics_total = @epics.count
    @epics = @epics.order(updated_at: :desc, id: :desc).offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

    kanban_scope = Current.user.epics
                                .where(repository_id: active_repo_ids)
                                .includes(:repository,
                                          { jobs: :repository },
                                          { dependencies: :depends_on_epic },
                                          { dependent_links: :epic })
    @epic_records = @filter.apply(kanban_scope).order(updated_at: :desc, id: :desc).to_a
    @epic_lanes = Epic::STATES.index_with { |state| @epic_records.select { |epic| epic.state == state } }
    @epics_matching_count = @epics_total
    # See epic_list — inactive-tab badge is the unfiltered total.
    @jobs_matching_count = jobs_total_for_dashboard(active_repo_ids)
    @workflows_matching_count = workflows_total_for_dashboard(active_repo_ids)
  end

  def load_dashboard
    # Dashboard hides archived repositories and everything that
    # belonged to them. Archiving is the operator's "I'm done with
    # this for now" gesture; surfacing the archived repo's stale
    # jobs and workflows back on the dashboard would defeat the
    # whole point. The /repositories index keeps a separate
    # "Archived" section for the cases where the operator does
    # want to look back at them.
    active_repo_ids = Current.user.repositories.active.pluck(:id)
    @repositories   = Current.user.repositories.active.order(:owner, :name)
    @tags           = Current.user.tags.ordered
    @configured_agent_providers = Current.user.configured_agent_providers
    @page           = [ params[:page].to_i, 1 ].max
    @dashboard_view = params[:view] == "kanban" ? "kanban" : "list"
    SmartFolder.ensure_builtins!
    @builtin_smart_folders = SmartFolder.builtins
    @user_smart_folders = SmartFolder.for_user(Current.user)
    @active_smart_folder = smart_folder_from_params

    # Eager-load workflows + their steps for current_step_caption(job),
    # and runs for the per-row cost rollup.
    @jobs = Current.user.jobs.where(repository_id: active_repo_ids)
                             .includes(:repository, :runs, workflows: :steps)

    @job_filter = Jobs::Filter.from_params(params, smart_folder: @active_smart_folder, user: Current.user)
    @jobs = @job_filter.apply(@jobs)
    @jobs_matching_count = @jobs.count
    # Inactive-tab badge — see comment in epic_list. Total epics across
    # the user's active repos, not the active job filter cross-applied.
    @epics_matching_count = epics_total_for_dashboard(active_repo_ids)
    @workflows_matching_count = workflows_total_for_dashboard(active_repo_ids)
    @epics = epics_for_active_smart_folder(active_repo_ids)
    @smart_folder_counts = smart_folder_counts(Current.user.jobs.where(repository_id: active_repo_ids))
    @landing_queue_entries = LandingQueueProcessor.entries(Current.user.jobs.where(repository_id: active_repo_ids)).index_by(&:job_id)

    # Split the built-ins into the primary sidebar list and the
    # collapsible "More" disclosure at the bottom. See
    # SmartFolder::BUILTIN_DEFINITIONS for visibility semantics:
    #   :always       — always in the primary list.
    #   :when_present — primary list only when there's something to show
    #                   (or it's the active folder, so the operator
    #                   isn't stranded mid-browse). Hidden entirely
    #                   otherwise — not demoted to "More".
    #   :on_demand    — always tucked under "More".
    @primary_builtin_smart_folders = []
    @more_builtin_smart_folders = []
    @builtin_smart_folders.each do |folder|
      case folder.visibility
      when :always
        @primary_builtin_smart_folders << folder
      when :on_demand
        @more_builtin_smart_folders << folder
      when :when_present
        if @smart_folder_counts[folder.id].to_i.positive? || @active_smart_folder == folder
          @primary_builtin_smart_folders << folder
        end
      else
        @primary_builtin_smart_folders << folder
      end
    end

    @jobs_total = @jobs.count
    @jobs = @jobs.includes(:tags)

    if @active_tab == "jobs" && @dashboard_view == "kanban"
      load_job_kanban
    end

    @jobs = if landing_queue_folder?
      ordered_ids = @landing_queue_entries.keys
      @jobs.sort_by { |job| ordered_ids.index(job.id) || ordered_ids.length }
    elsif @job_filter.pinned?
      # apply_attention(pinned) already joined job_pins; ordering by
      # the pin's created_at puts the most recently pinned jobs first.
      @jobs.order("job_pins.created_at DESC", created_at: :desc)
    else
      @jobs.order(created_at: :desc)
    end
    @jobs = @jobs.is_a?(Array) ? @jobs.slice((@page - 1) * PER_PAGE, PER_PAGE) || [] : @jobs.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    @pinned_job_ids = Current.user.job_pins.where(job_id: @jobs.map(&:id)).pluck(:job_id)

  end

  def load_workflows_dashboard
    active_repo_ids = Current.user.repositories.active.pluck(:id)
    @page = [ params[:page].to_i, 1 ].max
    @dashboard_view = params[:view] == "kanban" ? "kanban" : "list"

    SmartFolder.ensure_builtins!
    SmartFolder.ensure_workflow_builtins!
    @schema = ::Filters::Schema.for(subject: :workflow, user: Current.user)
    @active_smart_folder = workflow_smart_folder_from_params
    @workflow_filter = ::Workflows::Filter.from_params(params, smart_folder: @active_smart_folder, user: Current.user)
    @builtin_smart_folders = SmartFolder.for_subject(:workflow).built_in_sidebar_order
    @user_smart_folders = SmartFolder.for_user(Current.user, subject: :workflow)

    base_scope = Workflow.joins(:job)
                         .where(jobs: { user_id: Current.user.id, repository_id: active_repo_ids })
    @workflows_unfiltered_count = base_scope.count
    @smart_folder_counts = workflow_smart_folder_counts(base_scope)
    @primary_builtin_smart_folders, @more_builtin_smart_folders = split_builtin_smart_folders

    @workflows = @workflow_filter.apply(base_scope)
                                 .includes(:steps, job: :repository)
    @workflows_total = @workflows.count
    @workflows_matching_count = @workflows_total
    @jobs_matching_count = jobs_total_for_dashboard(active_repo_ids)
    @epics_matching_count = epics_total_for_dashboard(active_repo_ids)

    if @dashboard_view == "kanban"
      load_workflow_kanban
    else
      @workflows = @workflows.order(created_at: :desc, id: :desc)
                             .offset((@page - 1) * PER_PAGE)
                             .limit(PER_PAGE)
    end
  end

  def load_workflow_kanban
    @workflow_kanban_cap_hit = @workflows_total > KANBAN_PER_PAGE
    workflows = @workflows.order(created_at: :desc, id: :desc)
                          .limit(KANBAN_PER_PAGE)
                          .to_a
    @workflow_kanban_records = WORKFLOW_KANBAN_COLUMNS.to_h { |column| [ column, [] ] }
    workflows.each do |workflow|
      column = WORKFLOW_DONE_STATES.include?(workflow.state) ? "done" : workflow.state
      @workflow_kanban_records[column] << workflow if @workflow_kanban_records.key?(column)
    end
  end

  def load_job_kanban
    @job_kanban_cap_hit = @jobs_total > KANBAN_PER_PAGE
    kanban_jobs = @jobs
      .with_latest_workflow_snapshot
      .includes(:repository, :runs, { dependencies: :depends_on_job }, :tags)
      .order(created_at: :desc)
      .limit(KANBAN_PER_PAGE)
      .to_a

    @job_kanban_lanes = JOB_KANBAN_LANES.to_h { |lane| [ lane.fetch(:key), [] ] }
    kanban_jobs.each do |job|
      lane = JOB_KANBAN_LANES.find { |candidate| candidate.fetch(:key) == job.latest_workflow_state }&.fetch(:key) || "queued"
      @job_kanban_lanes[lane] << job
    end
  end

  def tag_filter_ids
    Current.user.tags.where(id: Array(params[:tag_ids]).compact_blank).pluck(:id)
  end

  def bulk_retry_jobs(jobs, agent_provider: nil)
    if agent_provider.present? && !Current.user.agent_provider_configured?(agent_provider)
      redirect_back fallback_location: dashboard_jobs_path, alert: "That agent is not available for retry."
      return
    end

    retried = 0
    jobs.find_each do |job|
      result = RetryWorkflowEnqueuer.call(job: job, agent_provider: agent_provider)
      retried += 1 if result.success?
    end

    if retried.zero?
      redirect_back fallback_location: dashboard_jobs_path, alert: "No selected jobs were eligible for retry."
    else
      agent_suffix = agent_provider.present? ? " with #{agent_provider.titleize}" : ""
      redirect_back fallback_location: dashboard_jobs_path,
                    notice: "Retry enqueued for #{helpers.pluralize(retried, 'job')}#{agent_suffix}."
    end
  end

  def bulk_close_jobs(jobs)
    closed = 0
    jobs.find_each do |job|
      next if job.closed?

      job.cancel_active_runs_and_close!("cancelled")
      closed += 1
    end

    if closed.zero?
      redirect_back fallback_location: dashboard_jobs_path, alert: "No selected jobs were open."
    else
      redirect_back fallback_location: dashboard_jobs_path,
                    notice: "#{helpers.pluralize(closed, 'job')} closed."
    end
  end

  def bulk_approve_jobs(jobs)
    batch_id = SecureRandom.uuid
    approved = 0
    approved_jobs = []
    skipped_auto_merge_disabled = []

    ActiveRecord::Base.transaction do
      jobs.each do |job|
        next unless job.may_approve?

        # Same guard as JobsController#approve — refuse approval on
        # repos without auto_merge_enabled so the operator's intent
        # isn't silently lost to a fail_landing cycle. Skipping here
        # is the bulk equivalent of the single-Job alert.
        unless job.repository.auto_merge_enabled?
          skipped_auto_merge_disabled << job
          next
        end

        job.approve!(
          via: "bulk",
          by_user: Current.user,
          evidence: { "batch_id" => batch_id }
        )
        approved += 1
        approved_jobs << job
      end
    end

    if approved.zero? && skipped_auto_merge_disabled.empty?
      redirect_back fallback_location: dashboard_jobs_path, alert: "No selected jobs were awaiting approval."
    elsif approved.zero?
      redirect_back fallback_location: dashboard_jobs_path,
                    alert: bulk_auto_merge_disabled_message(skipped_auto_merge_disabled)
    else
      github_note = bulk_github_approval_note(approved_jobs)
      skip_note = skipped_auto_merge_disabled.any? ? bulk_auto_merge_disabled_message(skipped_auto_merge_disabled) : nil
      redirect_back fallback_location: dashboard_jobs_path,
                    notice: [ "Approved #{helpers.pluralize(approved, 'job')} in batch #{batch_id}.", github_note, skip_note ].compact.join(" ")
    end
  end

  def bulk_auto_merge_disabled_message(skipped)
    repos = skipped.map { |job| job.repository.slug }.uniq.sort
    "Skipped #{helpers.pluralize(skipped.size, 'job')} whose repository has auto-merge disabled (#{repos.join(', ')}). Enable auto-merge in repository settings to approve."
  end

  def bulk_review_approval(jobs)
    @active_tab = "jobs"
    @bulk_review_jobs = jobs.where(state: "implemented")
                            .includes(:repository, :runs)
                            .order(created_at: :desc)
                            .to_a
    if @bulk_review_jobs.empty?
      redirect_back fallback_location: dashboard_jobs_path, alert: "No selected jobs were awaiting approval."
      return
    end

    load_dashboard
    render :index
  end

  def bulk_commit_review_approval(jobs)
    choices_param = params[:approval_choices]
    choices = choices_param.respond_to?(:to_unsafe_h) ? choices_param.to_unsafe_h : {}
    ids_to_approve = choices.select { |_id, choice| choice == "approve" }.keys
    reviewed_jobs = jobs.where(id: ids_to_approve, state: "implemented")

    if reviewed_jobs.empty?
      redirect_back fallback_location: dashboard_jobs_path, alert: "No reviewed jobs were approved."
      return
    end

    batch_id = SecureRandom.uuid
    approved = 0
    approved_jobs = []
    ActiveRecord::Base.transaction do
      reviewed_jobs.each do |job|
        job.approve!(
          via: "bulk",
          by_user: Current.user,
          evidence: { "batch_id" => batch_id }
        )
        approved += 1
        approved_jobs << job
      end
    end

    github_note = bulk_github_approval_note(approved_jobs)
    redirect_to dashboard_jobs_path,
                notice: [ "Approved #{helpers.pluralize(approved, 'job')} in batch #{batch_id}.", github_note ].compact.join(" ")
  end

  def bulk_github_approval_note(jobs)
    results = jobs.map { |job| Job::ApprovalPropagator.approve(job, user: Current.user) }
    successes = results.count(&:success?)
    failures = results.select(&:failure?)
    notes = []
    notes << "GitHub reviews left for #{helpers.pluralize(successes, 'job')}." if successes.positive?
    notes << failures.map(&:message).uniq.join(" ") if failures.any?
    notes.presence&.join(" ")
  end

  def smart_folder_from_params
    return if params[:smart_folder_id].blank?

    SmartFolder.builtins.find_by(id: params[:smart_folder_id]) ||
      SmartFolder.for_user(Current.user).find_by(id: params[:smart_folder_id])
  end

  def workflow_smart_folder_from_params
    return if params[:smart_folder_id].blank?

    SmartFolder.for_subject(:workflow).builtin.where(user_id: nil).find_by(id: params[:smart_folder_id]) ||
      SmartFolder.for_subject(:workflow).where(user: Current.user).find_by(id: params[:smart_folder_id])
  end

  def epic_smart_folder_from_params
    return if params[:smart_folder_id].blank?

    SmartFolder.for_subject(:epic).builtin.where(user_id: nil).find_by(id: params[:smart_folder_id]) ||
      SmartFolder.for_subject(:epic).where(user: Current.user).find_by(id: params[:smart_folder_id])
  end

  def epic_list_smart_folder_from_params
    epic_smart_folder_from_params
  end

  def epic_smart_folder_counts(base_scope)
    (@builtin_smart_folders + @smart_folders).to_h do |folder|
      [ folder.id, ::Epics::Filter.from_tree(folder.filter, user: Current.user).apply(base_scope).count ]
    end
  end

  def epic_list_smart_folder_counts(base_scope)
    epic_smart_folder_counts(base_scope)
  end

  def split_epic_builtin_smart_folders
    primary = []
    more = []

    @builtin_smart_folders.each do |folder|
      case folder.visibility
      when :always
        primary << folder
      when :on_demand
        more << folder
      when :when_present
        primary << folder if @smart_folder_counts[folder.id].to_i.positive? || @smart_folder == folder
      else
        primary << folder
      end
    end

    [ primary, more ]
  end

  def split_epic_list_builtin_smart_folders
    split_epic_builtin_smart_folders
  end

  # Unfiltered totals for the inactive-tab badge. Scoped to active
  # repos so archived-repo content doesn't inflate the count beyond
  # what the dashboard would actually surface.
  def jobs_total_for_dashboard(active_repo_ids = Current.user.repositories.active.select(:id))
    Current.user.jobs.where(repository_id: active_repo_ids).count
  end

  def epics_total_for_dashboard(active_repo_ids = Current.user.repositories.active.select(:id))
    Current.user.epics.where(repository_id: active_repo_ids).count
  end

  def workflows_total_for_dashboard(active_repo_ids = Current.user.repositories.active.select(:id))
    Workflow.joins(:job).where(jobs: { user_id: Current.user.id, repository_id: active_repo_ids }).count
  end

  def split_builtin_smart_folders
    primary = []
    more = []

    @builtin_smart_folders.each do |folder|
      case folder.visibility
      when :always
        primary << folder
      when :on_demand
        more << folder
      when :when_present
        primary << folder if @smart_folder_counts[folder.id].to_i.positive? || @active_smart_folder == folder
      else
        primary << folder
      end
    end

    [ primary, more ]
  end

  def workflow_smart_folder_counts(base_scope)
    (@builtin_smart_folders + @user_smart_folders).to_h do |folder|
      [ folder.id, ::Workflows::Filter.from_tree(folder.filter, user: Current.user).apply(base_scope).count ]
    end
  end

  def epic_filter_params
    params.permit(:repository_id, :blocked, :done, :sort).to_h.compact_blank
  end

  def sort_epics_for_board(epics, sort)
    case sort
    when "updated_asc"
      epics.sort_by { |epic| [ epic.updated_at || Time.zone.at(0), epic.id ] }
    else
      epics.sort_by { |epic| [ epic.updated_at || Time.zone.at(0), epic.id ] }.reverse
    end
  end

  def epic_blocked_for_board?(epic)
    epic.dependencies.any? { |dependency| !dependency.depends_on_epic.done? }
  end

  def smart_folder_counts(base_scope)
    (@builtin_smart_folders + @user_smart_folders).to_h do |folder|
      count = Jobs::Filter.from_tree(folder.filter, user: Current.user).apply(base_scope).count
      count += epic_count_for_filter(folder.filter)
      [ folder.id, count ]
    end
  end

  def landing_queue_folder?
    filter_has_attention_chip?(@job_filter.to_h, "landing_queue")
  end

  def epics_for_active_smart_folder(active_repo_ids)
    return Epic.none unless folder_uses_attention?(@active_smart_folder, "inbox")

    Epic.includes(:repository)
        .where(user: Current.user, repository_id: active_repo_ids, state: "ready")
        .order(updated_at: :desc, id: :desc)
  end

  def epic_count_for_filter(filter)
    return 0 unless filter_has_attention_chip?(filter, "inbox")

    Current.user.epics.joins(:repository)
           .where(repositories: { archived_at: nil })
           .where(state: "ready")
           .count
  end

  def folder_uses_attention?(folder, preset)
    filter_has_attention_chip?(folder&.filter, preset)
  end

  # Walks the AST tree shape looking for an `attention: <preset>`
  # chip anywhere — handles legacy folders just in case but mostly
  # serves the new tree-shape rows.
  def filter_has_attention_chip?(tree, preset)
    return false unless tree.is_a?(Hash)

    Array(tree["and"]).any? { |child| chip_matches_attention?(child, preset) } ||
      chip_matches_attention?(tree, preset)
  end

  def chip_matches_attention?(node, preset)
    return false unless node.is_a?(Hash)

    node["field"] == "attention" && node["value"].to_s == preset
  end

  def bulk_apply_tag(jobs)
    tag = find_or_create_bulk_tag
    return unless tag

    applied = 0
    jobs.find_each do |job|
      job.job_tags.find_or_create_by!(tag: tag)
      applied += 1
    end

    redirect_back fallback_location: dashboard_jobs_path,
                  notice: "Applied #{tag.name} to #{helpers.pluralize(applied, 'job')}."
  end

  def find_or_create_bulk_tag
    if params[:tag_id].present?
      tag = Current.user.tags.find_by(id: params[:tag_id])
      unless tag
        redirect_back fallback_location: dashboard_jobs_path, alert: "Tag not found."
        return nil
      end
      return tag
    end

    name = params[:tag_name].to_s.strip
    if name.blank?
      redirect_back fallback_location: dashboard_jobs_path, alert: "Choose or enter a tag."
      return nil
    end

    Current.user.tags.find_or_create_by!(name: name) { |tag| tag.color = "gray" }
  end
end
