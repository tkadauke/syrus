module Throughput
  module Callbacks
    include Syrus::Host::Callbacks

    def self.on_tick
      Syrus::Host::RepositoryRecord.active.find_each do |repository|
        next unless RepositorySnapshot.new(repository: repository).refresh_needed?

        RefreshRepositorySnapshotJob.perform_later(repository.id)
      end
      nil
    end
  end
end
