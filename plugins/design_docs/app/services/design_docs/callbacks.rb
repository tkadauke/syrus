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
      defined?(::GlobalSearch) && ::GlobalSearch.respond_to?(:enabled?) && ::GlobalSearch.enabled?
    end
  end
end
