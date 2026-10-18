class Throughput::RefreshRepositorySnapshotJob < ApplicationJob
  queue_as :polling

  limits_concurrency to: 1, key: ->(repository_id) { "throughput-snapshot:#{repository_id}" }

  def perform(repository_id)
    repository = Repository.active.find_by(id: repository_id)
    return unless repository

    Throughput::RepositorySnapshot.new(repository: repository).refresh!
  end
end
