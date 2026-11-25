class IndexJobSearchJob < Syrus::Host::PluginJob
  plugin :global_search

  def perform(job_id)
    job = Syrus::Host::JobRecord.find_by(id: job_id)
    return unless job

    GlobalSearch::JobIndex.upsert(job)
  end
end
