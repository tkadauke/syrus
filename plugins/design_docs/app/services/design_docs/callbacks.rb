module DesignDocs
  class Callbacks
    include Syrus::Host::Callbacks

    def self.on_enable
      return unless global_search_available?

      Rails.application.load_tasks unless defined?(Syrus::Host::SearchDatabaseTasks)
      Syrus::Host::SearchDatabaseTasks.prepare!
      DesignDocs::SearchSource.backfill_search_table("design_doc_fts")
    end

    def self.global_search_available?
      manifest = Syrus::Host::PluginRegistry.all_plugins.find { |candidate| candidate.name == "global_search" }
      manifest&.enabled? && Syrus::Host::PluginRegistry.health.healthy?("global_search")
    end
  end
end
