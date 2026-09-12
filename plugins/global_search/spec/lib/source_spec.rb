require "rails_helper"
require "rake"

RSpec.describe "search_source plugin tables", :reset_plugin_registry do
  before(:all) { Rails.application.load_tasks }

  before do
    GlobalSearch.register!
  end

  def provider(tables)
    Class.new do
      class_attribute :declared_tables, :rebuilt
      self.declared_tables = tables
      self.rebuilt = []

      def self.search_tables = declared_tables
      def self.backfill_search_table(name) = self.rebuilt += [ name ]
      def self.rebuild_search_table(name) = self.rebuilt += [ name ]
    end
  end

  def register(klass)
    Syrus::PluginRegistry.register(name: "search_table_plugin", version: "1.0.0", provides: { "global_search:source" => klass })
  end

  it "merges plugin tables into the required set" do
    register(provider({ "plugin_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS plugin_fts USING fts5(body)" }))

    expect(SyrusSearchDatabaseTasks.required_table_sql).to have_key("plugin_fts")
  end

  it "keeps the built-in tables" do
    register(provider({ "plugin_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS plugin_fts USING fts5(body)" }))

    expect(SyrusSearchDatabaseTasks.required_table_sql.keys).to include("chat_message_fts", "job_fts")
  end

  it "refuses to let a plugin redefine a built-in table" do
    register(provider({ "job_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS job_fts USING fts5(hijacked)" }))

    expect(SyrusSearchDatabaseTasks.required_table_sql["job_fts"]).to include("title")
  end

  it "drops the plugin's tables when the plugin is disabled" do
    register(provider({ "plugin_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS plugin_fts USING fts5(body)" }))
    PluginRecord.find_or_create_by!(name: "search_table_plugin").update!(enabled: false, disableable: true)

    expect(SyrusSearchDatabaseTasks.required_table_sql).not_to have_key("plugin_fts")
  end

  it "returns no plugin tables when the global_search host is disabled" do
    register(provider({ "plugin_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS plugin_fts USING fts5(body)" }))
    PluginRecord.find_or_create_by!(name: "global_search").update!(enabled: false, disableable: true)

    expect(Syrus::PluginRegistry.providers_for("global_search:source")).to eq([])
    expect(SyrusSearchDatabaseTasks.required_table_sql).not_to have_key("plugin_fts")
  end

  it "exposes a plugin rebuild hook for its own table" do
    klass = provider({ "plugin_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS plugin_fts USING fts5(body)" })
    register(klass)

    SyrusSearchDatabaseTasks.plugin_rebuild_hook("plugin_fts").call

    expect(klass.rebuilt).to eq([ "plugin_fts" ])
  end

  it "has no rebuild hook for a table nobody claims" do
    expect(SyrusSearchDatabaseTasks.plugin_rebuild_hook("unclaimed_fts")).to be_nil
  end

  it "isolates plugin table declaration failures while preparing other providers" do
    broken_provider = Class.new do
      def self.search_tables = raise "nope"
    end
    healthy_provider = provider({ "healthy_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS healthy_fts USING fts5(body)" })

    Syrus::PluginRegistry.register(name: "broken_search_plugin", version: "1.0.0", provides: { "global_search:source" => broken_provider })
    Syrus::PluginRegistry.register(name: "healthy_search_plugin", version: "1.0.0", provides: { "global_search:source" => healthy_provider })

    expect(SyrusSearchDatabaseTasks.required_table_sql).to have_key("healthy_fts")
  end

  it "backfills every enabled provider and isolates provider failures" do
    broken_provider = Class.new do
      def self.search_tables = { "broken_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS broken_fts USING fts5(body)" }
      def self.backfill_search_table(_name) = raise "backfill exploded"
    end
    healthy_provider = provider({ "healthy_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS healthy_fts USING fts5(body)" })

    Syrus::PluginRegistry.register(name: "broken_search_plugin", version: "1.0.0", provides: { "global_search:source" => broken_provider })
    Syrus::PluginRegistry.register(name: "healthy_search_plugin", version: "1.0.0", provides: { "global_search:source" => healthy_provider })

    expect { GlobalSearch::SourceBackfill.run! }.not_to raise_error
    expect(healthy_provider.rebuilt).to eq([ "healthy_fts" ])
  end

  it "uses the legacy rebuild hook as the backfill hook" do
    legacy_provider = Class.new do
      class_attribute :rebuilt
      self.rebuilt = []

      def self.search_tables = { "legacy_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS legacy_fts USING fts5(body)" }
      def self.rebuild_search_table(name) = self.rebuilt += [ name ]
    end

    Syrus::PluginRegistry.register(name: "legacy_search_plugin", version: "1.0.0", provides: { "global_search:source" => legacy_provider })

    GlobalSearch::SourceBackfill.run!

    expect(legacy_provider.rebuilt).to eq([ "legacy_fts" ])
  end

  it "prepares tables before backfilling when global_search is enabled" do
    calls = []

    allow(SyrusSearchDatabaseTasks).to receive(:prepare!) { calls << :prepare }
    allow(GlobalSearch::SourceBackfill).to receive(:run!) { calls << :backfill }

    GlobalSearch::Callbacks.on_enable

    expect(calls).to eq([ :prepare, :backfill ])
  end
end
