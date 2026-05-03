class HomeController < ApplicationController
  def index
    @jobs = Current.user.jobs.includes(:repository).order(created_at: :desc).limit(20)
    @runs = Run.joins(:job).where(jobs: { user_id: Current.user.id })
               .includes(job: :repository).order(created_at: :desc).limit(50)
    @active_tab = params[:tab] == "runs" ? "runs" : "jobs"
  end
end
