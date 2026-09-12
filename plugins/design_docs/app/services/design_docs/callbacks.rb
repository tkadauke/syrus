module DesignDocs
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_enable
      return unless global_search_available?

      Rails.application.load_tasks unless defined?(SyrusSearchDatabaseTasks)
      SyrusSearchDatabaseTasks.prepare!
      DesignDocs::SearchSource.backfill_search_table("design_doc_fts")
    end

    def self.global_search_available?
      manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == "global_search" }
      manifest&.enabled? && Syrus::PluginRegistry.health.healthy?("global_search")
    end
  end
end
