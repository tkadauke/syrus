module GlobalSearch
  class Callbacks
    include Syrus::Host::Callbacks

    def self.on_enable
      Rails.application.load_tasks unless defined?(Syrus::Host::SearchDatabaseTasks)

      Syrus::Host::SearchDatabaseTasks.prepare!
      GlobalSearch::SourceBackfill.run!
    end
  end
end
