module GlobalSearch
  # Marker interface for plugins that own a full-text search index and, on
  # top of it, a result type in global search.
  #
  # Core keeps the search *database* (SearchRecord, the FTS schema); this
  # plugin owns the search *feature*.
  #
  # A provider declares its tables:
  #
  #   def self.search_tables
  #     { "my_plugin_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS ..." }
  #   end
  #
  # and, optionally, an idempotent backfill hook. Global Search calls it after
  # the host plugin is enabled and after a table is created or rebuilt by
  # `syrus:prepare_search`, so it must be safe to run repeatedly. Without one,
  # a drifted table is left alone and the drift is logged, because losing rows
  # Syrus cannot rebuild is worse than running on a stale schema:
  #
  #   def self.backfill_search_table(name) = MyPlugin::Index.rebuild!
  #
  # The older name remains supported as an alias for the same semantics:
  #
  #   def self.rebuild_search_table(name) = MyPlugin::Index.rebuild!
  #
  # A provider may also contribute a global-search result type:
  #
  #   def self.search_type = "my_thing"
  #   def self.search(query:, user:, limit:) = [ { id:, title:, path: } ]
  # The contract for a search result type contributed through this plugin's
  # "global_search:source" point.
  #
  # Contributors do not `include` this module: doing so would make them load a
  # Search constant, turning an optional hook into a hard load-time dependency
  # on this plugin. It documents the contract; contributors duck-type it.
  module Source
  end
end
