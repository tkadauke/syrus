module GlobalSearch
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_enable
      Rails.application.load_tasks unless defined?(SyrusSearchDatabaseTasks)

      SyrusSearchDatabaseTasks.prepare!
      GlobalSearch::SourceBackfill.run!
    end
  end
end
