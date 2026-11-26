class Throughput::RefreshRepositorySnapshotJob < PluginJob
  plugin :throughput, concurrency: 1

  def perform(repository_id)
    repository = Syrus::Host::RepositoryRecord.active.find_by(id: repository_id)
    return unless repository

    Throughput::RepositorySnapshot.new(repository: repository).refresh!
  end
end
