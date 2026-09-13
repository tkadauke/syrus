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
  #   def self.search_rows(query:, user:, limit:) = [ { my_thing_id:, rank:, snippet: } ]
  #   def self.row_id_key = :my_thing_id
  #   def self.result_json(row:, user:) = { id:, title:, path: }
  #
  # Providers that own built-in or plugin search tables can also expose
  # maintenance rebuild hooks:
  #
  #   def self.search_table_name = "my_plugin_fts"
  #   def self.search_id_column = "my_plugin_id"
  #   def self.records = MyPlugin::Record.order(:id)
  #   def self.count = MyPlugin::Record.count
  #   def self.exists? = MyPlugin::Record.exists?
  #   def self.upsert(record) = MyPlugin::Index.upsert(record)
  #
  # Legacy providers may expose narrower built-in hooks instead:
  #
  #   def self.index_job(job) = ...
  #   def self.index_epic(epic) = ...
  # The contract for a search result type contributed through this plugin's
  # "global_search:source" point.
  #
  # The global_search plugin also uses this hosted point for optional
  # maintenance hooks that backfill built-in core models without core naming
  # plugin-owned index constants:
  #
  # Contributors do not `include` this module: doing so would make them load a
  # Search constant, turning an optional hook into a hard load-time dependency
  # on this plugin. It documents the contract; contributors duck-type it.
  module Source
  end
end
