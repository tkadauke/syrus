module Throughput
  module Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      Repository.active.where(polling_enabled: true).find_each do |repository|
        RefreshRepositorySnapshotJob.perform_later(repository.id)
      end
      nil
    end
  end
end
