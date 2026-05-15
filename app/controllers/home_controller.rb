class HomeController < ApplicationController
  PER_PAGE = 25
  HIDE_BUILTIN_WHEN_EMPTY = %w[ pinned in_progress ].freeze

  def index
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
    @active_tab     = params[:tab] == "workflows" ? "workflows" : "jobs"
    @page           = [ params[:page].to_i, 1 ].max
    SmartFolder.ensure_builtins!
    @builtin_smart_folders = SmartFolder.builtins
    @user_smart_folders = SmartFolder.for_user(Current.user)
    @active_smart_folder = smart_folder_from_params

    # Eager-load workflows + their steps for current_step_caption(job),
    # and runs for the per-row cost rollup.
    @jobs = Current.user.jobs.where(repository_id: active_repo_ids)
                             .includes(:repository, :runs, workflows: :steps)

    @job_filter_params = job_filter_params
    @job_filter = Jobs::Filter.new(@job_filter_params, user: Current.user)
    @jobs = @job_filter.apply(@jobs)
    @smart_folder_counts = smart_folder_counts(Current.user.jobs.where(repository_id: active_repo_ids))

    # Hide built-in folders whose attention is in HIDE_BUILTIN_WHEN_EMPTY
    # when they have zero matches — keeps the nav from advertising
    # features the operator isn't currently using. Stay visible if it's
    # the active folder so they're not stranded mid-browse.
    @builtin_smart_folders = @builtin_smart_folders.reject do |folder|
      HIDE_BUILTIN_WHEN_EMPTY.include?(folder.filter["attention"]) &&
        @smart_folder_counts[folder.id].to_i.zero? &&
        @active_smart_folder != folder
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

  def bulk_jobs
    job_ids = Array(params[:job_ids]).filter_map { |id| Integer(id, exception: false) }.uniq
    if job_ids.empty?
      redirect_back fallback_location: root_path, alert: "Select at least one job."
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
    when "apply_tag"
      bulk_apply_tag(jobs)
    else
      redirect_back fallback_location: root_path, alert: "Choose a bulk action."
    end
  end

  private

  def tag_filter_ids
    Current.user.tags.where(id: Array(params[:tag_ids]).compact_blank).pluck(:id)
  end

  def bulk_retry_jobs(jobs, agent_provider: nil)
    if agent_provider.present? && !Current.user.agent_provider_configured?(agent_provider)
      redirect_back fallback_location: root_path, alert: "That agent is not available for retry."
      return
    end

    retried = 0
    jobs.find_each do |job|
      next if job.closed? || job.any_active_run?

      job.switch_agent_provider!(agent_provider) if agent_provider.present?
      job.sync_skip_prepare_from_source!
      workflow = Workflows::Retry.instantiate(job: job, agent_provider: agent_provider)
      StepDispatcher.start_workflow(workflow)
      retried += 1
    end

    if retried.zero?
      redirect_back fallback_location: root_path, alert: "No selected jobs were eligible for retry."
    else
      agent_suffix = agent_provider.present? ? " with #{agent_provider.titleize}" : ""
      redirect_back fallback_location: root_path,
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
      redirect_back fallback_location: root_path, alert: "No selected jobs were open."
    else
      redirect_back fallback_location: root_path,
                    notice: "#{helpers.pluralize(closed, 'job')} closed."
    end
  end

  def smart_folder_from_params
    return if params[:smart_folder_id].blank?

    SmartFolder.builtins.find_by(id: params[:smart_folder_id]) ||
      SmartFolder.for_user(Current.user).find_by(id: params[:smart_folder_id])
  end

  def job_filter_params
    base = params.permit(:state, :repository_id, :kind, :pr, :age, :attention).to_h.compact_blank
    base["tag_ids"] = tag_filter_ids if params[:tag_ids].present?

    if @active_smart_folder
      # The smart folder's filter is the floor; the operator can layer
      # additional URL filters on top (e.g. filter by state within a folder).
      @active_smart_folder.filter.merge(base)
    else
      base
    end
  end

  def smart_folder_counts(base_scope)
    (@builtin_smart_folders + @user_smart_folders).to_h do |folder|
      [ folder.id, Jobs::Filter.new(folder.filter, user: Current.user).apply(base_scope).count ]
    end
  end

  def bulk_apply_tag(jobs)
    tag = find_or_create_bulk_tag
    return unless tag

    applied = 0
    jobs.find_each do |job|
      job.job_tags.find_or_create_by!(tag: tag)
      applied += 1
    end

    redirect_back fallback_location: root_path,
                  notice: "Applied #{tag.name} to #{helpers.pluralize(applied, 'job')}."
  end

  def find_or_create_bulk_tag
    if params[:tag_id].present?
      tag = Current.user.tags.find_by(id: params[:tag_id])
      unless tag
        redirect_back fallback_location: root_path, alert: "Tag not found."
        return nil
      end
      return tag
    end

    name = params[:tag_name].to_s.strip
    if name.blank?
      redirect_back fallback_location: root_path, alert: "Choose or enter a tag."
      return nil
    end

    Current.user.tags.find_or_create_by!(name: name) { |tag| tag.color = "gray" }
  end
end
