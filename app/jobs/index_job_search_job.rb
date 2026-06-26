class IndexJobSearchJob < ApplicationJob
  queue_as :default

  def perform(job_id)
    job = Job.find_by(id: job_id)
    return unless job

    JobSearchIndex.upsert(job)
  end
end
