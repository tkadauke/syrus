module Throughput
  module Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      Repository.active.find_each do |repository|
        RefreshRepositorySnapshotJob.perform_later(repository.id)
      end
      nil
    end
  end
end
