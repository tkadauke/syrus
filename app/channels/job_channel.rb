class JobChannel < ApplicationCable::Channel
  def self.stream_name(job_id)
    "job_resource:#{job_id}"
  end

  def subscribed
    job = Job.accessible_to(current_user).find_by(id: params[:job_id])
    return reject unless job

    stream_from self.class.stream_name(job.id)
  end
end
