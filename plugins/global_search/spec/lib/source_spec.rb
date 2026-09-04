require "rails_helper"
require "rake"

RSpec.describe "search_source plugin tables" do
  before(:all) { Rails.application.load_tasks }

  def provider(tables, rebuild: nil)
    Class.new do
      include GlobalSearch::Source

      class_attribute :declared_tables, :rebuilt
      self.declared_tables = tables
      self.rebuilt = []

      def self.search_tables = declared_tables
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

  it "exposes a plugin rebuild hook for its own table" do
    klass = provider({ "plugin_fts" => "CREATE VIRTUAL TABLE IF NOT EXISTS plugin_fts USING fts5(body)" })
    register(klass)

    SyrusSearchDatabaseTasks.plugin_rebuild_hook("plugin_fts").call

    expect(klass.rebuilt).to eq([ "plugin_fts" ])
  end

  it "has no rebuild hook for a table nobody claims" do
    expect(SyrusSearchDatabaseTasks.plugin_rebuild_hook("unclaimed_fts")).to be_nil
  end
end
