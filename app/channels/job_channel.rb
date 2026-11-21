class JobChannel < ApplicationCable::Channel
  include JobEpicRefFinder

  # How long a visibility answer is trusted before a delivery rechecks it.
  # Bounds how long a revoked user can keep receiving a Job's patches without
  # turning every high-churn Workflow/Step/Run patch into a query.
  VISIBILITY_RECHECK_INTERVAL = 10.seconds

  def self.stream_name(job_id)
    "job_resource:#{job_id}"
  end

  def subscribed
    job = find_job_by_ref(Job.visible_to(current_user), params[:job_id])
    @job_id = job.id
    @visible_checked_at = Time.current

    stream_from(self.class.stream_name(job.id), coder: ActiveSupport::JSON) { |message| deliver(message) }
  rescue ActiveRecord::RecordNotFound
    reject
  end

  private

  # The stream is shared by every subscriber of the Job, and visibility was
  # checked only on subscribe, so a user who lost access kept receiving
  # patches until the tab reconnected. Each delivery rechecks the same
  # Job.visible_to the subscription used; once it fails the stream stops and
  # nothing more is sent (formal/SyrusModel/ScopedDelivery.lean).
  def deliver(message)
    return transmit(message) if still_visible?

    stop_all_streams
  end

  def still_visible?
    return true if @visible_checked_at && @visible_checked_at > VISIBILITY_RECHECK_INTERVAL.ago

    visible = Job.visible_to(current_user).exists?(id: @job_id)
    @visible_checked_at = Time.current if visible
    visible
  end
end
