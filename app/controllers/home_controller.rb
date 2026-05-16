class HomeController < ApplicationController
  PER_PAGE = 25

  def index
    redirect_to default_chat_path
  end

  def epics
    @active_tab = "epics"
    load_epics_dashboard
    render :index
  end

  def jobs
    @active_tab = "jobs"
    load_dashboard
    render :index
  end

  def workflows
    @active_tab = "workflows"
    load_dashboard
    render :index
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

  private

  def load_epics_dashboard
    active_repositories = Current.user.repositories.active.order(:owner, :name)
    @epic_repositories = active_repositories
    @epic_filter_params = epic_filter_params

    epics = Current.user.epics
                        .where(repository_id: active_repositories.select(:id))
                        .includes(:repository, { jobs: :repository }, { dependencies: :depends_on_epic }, { dependent_links: :epic })

    if @epic_filter_params["repository_id"].present?
      epics = epics.where(repository_id: @epic_filter_params["repository_id"])
    end

    @show_done_epics = @epic_filter_params["done"] == "1"
    epics = epics.where.not(state: "done") unless @show_done_epics

    epics = epics.to_a
    if @epic_filter_params["blocked"] == "1"
      epics = epics.select { |epic| epic_blocked_for_board?(epic) }
    end

    epics = sort_epics_for_board(epics, @epic_filter_params["sort"])
    @epic_lanes = Epic::STATES.index_with { |state| epics.select { |epic| epic.state == state } }
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
    @epics = epics_for_active_smart_folder(active_repo_ids)
    @smart_folder_counts = smart_folder_counts(Current.user.jobs.where(repository_id: active_repo_ids))

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
    @jobs = if @job_filter.pinned?
      # apply_attention(pinned) already joined job_pins; ordering by
      # the pin's created_at puts the most recently pinned jobs first.
      @jobs.order("job_pins.created_at DESC", created_at: :desc)
    else
      @jobs.order(created_at: :desc)
    end
    @jobs = @jobs.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    @pinned_job_ids = Current.user.job_pins.where(job_id: @jobs.map(&:id)).pluck(:job_id)

    # Workflows tab — every burst of work, newest first. Eager-load
    # job→repository for the row, plus steps so the "currently"
    # caption can name the active step without an extra query.
    @workflows = Workflow.joins(:job)
                         .where(jobs: { user_id: Current.user.id, repository_id: active_repo_ids })
                         .includes(:steps, job: :repository)
    @workflows_total = @workflows.count
    @workflows = @workflows.order(created_at: :desc).offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
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

    ActiveRecord::Base.transaction do
      jobs.each do |job|
        next unless job.may_approve?

        job.approve!(
          via: "bulk",
          by_user: Current.user,
          evidence: { "batch_id" => batch_id }
        )
        approved += 1
      end
    end

    if approved.zero?
      redirect_back fallback_location: dashboard_jobs_path, alert: "No selected jobs were awaiting approval."
    else
      redirect_back fallback_location: dashboard_jobs_path,
                    notice: "Approved #{helpers.pluralize(approved, 'job')} in batch #{batch_id}."
    end
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
    ActiveRecord::Base.transaction do
      reviewed_jobs.each do |job|
        job.approve!(
          via: "bulk",
          by_user: Current.user,
          evidence: { "batch_id" => batch_id }
        )
        approved += 1
      end
    end

    redirect_to dashboard_jobs_path, notice: "Approved #{helpers.pluralize(approved, 'job')} in batch #{batch_id}."
  end

  def smart_folder_from_params
    return if params[:smart_folder_id].blank?

    SmartFolder.builtins.find_by(id: params[:smart_folder_id]) ||
      SmartFolder.for_user(Current.user).find_by(id: params[:smart_folder_id])
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
