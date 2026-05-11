class HomeController < ApplicationController
  PER_PAGE = 25

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
    @configured_agent_providers = Current.user.configured_agent_providers
    @active_tab     = params[:tab] == "workflows" ? "workflows" : "jobs"
    @page           = [ params[:page].to_i, 1 ].max

    # Eager-load workflows + their steps for current_step_caption(job),
    # and runs for the per-row cost rollup.
    @jobs = Current.user.jobs.where(repository_id: active_repo_ids)
                             .includes(:repository, :runs, workflows: :steps)
    case params[:state]
    when "open", "closed"
      @jobs = @jobs.where(state: params[:state])
    when "failed", "succeeded"
      @jobs = @jobs.open_threads.where(id: latest_workflow_job_ids(params[:state]))
    end
    @jobs = @jobs.where(repository_id: params[:repository_id]) if params[:repository_id].present?

    case params[:pr]
    when "has_pr" then @jobs = @jobs.with_pr
    when "no_pr"  then @jobs = @jobs.without_pr
    end

    if params[:age].present?
      cutoff = { "1d" => 1.day.ago, "7d" => 7.days.ago, "30d" => 30.days.ago }[params[:age]]
      @jobs = @jobs.where(created_at: cutoff..) if cutoff
    end

    @jobs_total = @jobs.count
    @jobs = @jobs.order(created_at: :desc).offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

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
    else
      redirect_back fallback_location: root_path, alert: "Choose a bulk action."
    end
  end

  private

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

  def latest_workflow_job_ids(state)
    Workflow.where(state: state)
            .where(<<~SQL.squish)
              workflows.id = (
                SELECT latest_workflows.id
                FROM workflows latest_workflows
                WHERE latest_workflows.job_id = workflows.job_id
                ORDER BY latest_workflows.created_at DESC, latest_workflows.id DESC
                LIMIT 1
              )
            SQL
            .select(:job_id)
  end
end
