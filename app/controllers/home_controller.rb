class HomeController < ApplicationController
  PER_PAGE = 25

  def index
    @repositories = Current.user.repositories.order(:owner, :name)
    @active_tab = params[:tab] == "runs" ? "runs" : "jobs"
    @page = [params[:page].to_i, 1].max

    @jobs = Current.user.jobs.includes(:repository)
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

    @runs = Run.joins(:job).where(jobs: { user_id: Current.user.id })
               .includes(job: :repository)
    @runs_total = @runs.count
    @runs = @runs.order(created_at: :desc).offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end
end
