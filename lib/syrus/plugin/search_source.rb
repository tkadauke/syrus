module Syrus
  module Plugin
    # Marker interface for plugins that own a full-text search index and, on
    # top of it, a result type in global search.
    #
    # The search subsystem is core infrastructure and stays that way -- it
    # serves chats, jobs, epics, logs, and browser errors, and the plugin
    # registry has no business owning a database. But its two extension seams
    # were closed: SyrusSearchDatabaseTasks::REQUIRED_TABLE_SQL was a frozen
    # constant, and Api::V1::App::SearchController's TYPES and dispatch tables
    # were hardcoded, so a plugin could neither create an FTS table nor put a
    # result in front of anyone.
    #
    # A provider declares its tables:
    #
    #   def self.search_tables
    #     { "my_plugin_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS ..." }
    #   end
    #
    # and, optionally, a repopulation hook used when a table's schema has
    # drifted and it must be dropped and recreated. Without one the table is
    # left alone and the drift is logged, because losing rows Syrus cannot
    # rebuild is worse than running on a stale schema:
    #
    #   def self.rebuild_search_table(name) = MyPlugin::Index.rebuild!
    #
    # A provider may also contribute a global-search result type:
    #
    #   def self.search_type = "my_thing"
    #   def self.search(query:, user:, limit:) = [ { id:, title:, path: } ]
    module SearchSource
    end
  end
end
