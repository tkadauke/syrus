class IndexJobSearchJob < PluginJob
  plugin :global_search

  def perform(job_id)
    job = Job.find_by(id: job_id)
    return unless job

    GlobalSearch::JobIndex.upsert(job)
  end
end
