class IndexJobSearchJob < PluginJob
  queue_as :indexing

  def perform(job_id)
    job = Job.find_by(id: job_id)
    return unless job

    GlobalSearch::JobIndex.upsert(job)
  end
end
