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
    @active_tab     = params[:tab] == "workflows" ? "workflows" : "jobs"
    @page           = [ params[:page].to_i, 1 ].max

    # Eager-load workflows + their steps for current_step_caption(job),
    # and runs for the per-row cost rollup.
    @jobs = Current.user.jobs.where(repository_id: active_repo_ids)
                             .includes(:repository, :runs, workflows: :steps)
    @jobs = @jobs.where(state: params[:state]) if params[:state].present?
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
end
