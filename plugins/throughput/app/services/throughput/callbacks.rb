module Throughput
  module Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      Repository.active.find_each do |repository|
        next unless RepositorySnapshot.new(repository: repository).refresh_needed?

        RefreshRepositorySnapshotJob.perform_later(repository.id)
      end
      nil
    end
  end
end
