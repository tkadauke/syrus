class JobChannel < ApplicationCable::Channel
  include JobEpicRefFinder

  def self.stream_name(job_id)
    "job_resource:#{job_id}"
  end

  def subscribed
    job = find_job_by_ref(Job.accessible_to(current_user), params[:job_id])

    stream_from self.class.stream_name(job.id)
  rescue ActiveRecord::RecordNotFound
    reject
  end
end
