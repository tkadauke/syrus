class JobPinsController < ApplicationController
  before_action :load_job

  def create
    Current.user.job_pins.find_or_create_by!(job: @job)
    redirect_back fallback_location: job_path(@job), notice: "Job pinned."
  end

  def destroy
    Current.user.job_pins.find_by(job: @job)&.destroy!
    redirect_back fallback_location: job_path(@job), notice: "Job unpinned."
  end

  private

  def load_job
    @job = Current.user.jobs.find(params[:job_id])
  end
end
