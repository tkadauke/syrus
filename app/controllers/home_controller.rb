class HomeController < ApplicationController
  def index
    @repositories = Current.user.repositories.order(:owner, :name)

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

    @jobs = @jobs.order(created_at: :desc).limit(50)

    @runs = Run.joins(:job).where(jobs: { user_id: Current.user.id })
               .includes(job: :repository).order(created_at: :desc).limit(50)
    @active_tab = params[:tab] == "runs" ? "runs" : "jobs"
  end
end
