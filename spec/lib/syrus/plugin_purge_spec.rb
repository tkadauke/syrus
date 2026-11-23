require "rails_helper"

RSpec.describe Syrus::PluginPurge do
  describe "#report" do
    it "lists the tables a bundled plugin's models declare", requires_plugin: "build_cache" do
      report = described_class.new("build_cache").report

      expect(report.tables).to eq([ "build_cache_clear_requests", "build_cache_repository_settings" ])
      expect(report.row_counts).to have_key("build_cache_clear_requests")
    end

    it "counts existing rows", requires_plugin: "build_cache" do
      ENV["SCCACHE_BUCKET"] = "spec-bucket"
      BuildCache::ClearRequest.create!(scope: "full", reason: "spec", user: Factories.user)

      expect(described_class.new("build_cache").report.total_rows).to eq(1)
    ensure
      ENV.delete("SCCACHE_BUCKET")
    end

    it "reports nothing for a plugin that owns no tables", requires_plugin: "throughput" do
      expect(described_class.new("throughput").report).to be_empty
    end

    it "reports nothing for a plugin that was never installed" do
      expect(described_class.new("no_such_plugin").report).to be_empty
    end

    it "reports manifest-declared inline fields and plugin-owned rows" do
      connection = ActiveRecord::Base.connection
      connection.create_table(:plugin_purge_hosts) do |t|
        t.integer :plugin_owner_id
        t.string :plugin_policy
      end
      connection.execute("INSERT INTO plugin_purge_hosts (plugin_owner_id, plugin_policy) VALUES (42, 'active')")
      connection.execute("INSERT INTO plugin_purge_hosts (plugin_owner_id, plugin_policy) VALUES (NULL, NULL)")
      purge = described_class.new("no_such_plugin")
      allow(purge).to receive(:inline_field_configuration).and_return(
        "plugin_purge_hosts" => {
          "delete_rows_where_present" => "plugin_owner_id",
          "drop_columns" => %w[plugin_owner_id plugin_policy]
        }
      )

      expect(purge.report).to have_attributes(
        inline_fields: contain_exactly(
          have_attributes(table: "plugin_purge_hosts", column: "plugin_owner_id"),
          have_attributes(table: "plugin_purge_hosts", column: "plugin_policy")
        ),
        inline_row_counts: { "plugin_purge_hosts" => 1 },
        empty?: false,
        total_rows: 1
      )
    ensure
      connection&.drop_table(:plugin_purge_hosts, if_exists: true)
    end
  end

  describe "#purge!" do
    it "refuses while the plugin is still installed", requires_plugin: "build_cache" do
      expect { described_class.new("build_cache").purge! }
        .to raise_error(described_class::PluginStillInstalled, /still installed/)
    end

    it "never claims a core table even if a plugin migration names one", requires_plugin: "build_cache" do
      purge = described_class.new("build_cache")
      allow(purge).to receive(:migration_tables).and_return([ "jobs", "users" ])

      expect(purge.tables).not_to include("jobs", "users")
    end

    it "drops the plugin's tables and its PluginRecord row when forced", requires_plugin: "build_cache" do
      PluginRecord.find_or_create_by!(name: "build_cache")

      dropped = described_class.new("build_cache").purge!(force: true)

      expect(dropped).to eq([ "build_cache_clear_requests", "build_cache_repository_settings" ])
      expect(ActiveRecord::Base.connection.table_exists?("build_cache_clear_requests")).to be(false)
      expect(ActiveRecord::Base.connection.table_exists?("build_cache_repository_settings")).to be(false)
      expect(PluginRecord.exists?(name: "build_cache")).to be(false)
    ensure
      ActiveRecord::Migration.suppress_messages do
        ActiveRecord::Base.connection.create_table("build_cache_clear_requests") do |t|
          t.datetime :cancelled_at
          t.datetime :confirmed_at
          t.integer :older_than_days
          t.text :reason, null: false
          t.json :result
          t.string :scope, null: false
          t.string :state, default: "pending"
          t.integer :user_id
          t.timestamps
        end

        ActiveRecord::Base.connection.create_table("build_cache_repository_settings") do |t|
          t.references :repository, null: false, index: { unique: true }
          t.boolean :basedirs_safe, null: false, default: false
          t.timestamps
        end
      end
    end

    it "deletes plugin-owned rows before dropping manifest-declared inline fields" do
      connection = ActiveRecord::Base.connection
      connection.create_table(:plugin_purge_hosts) do |t|
        t.integer :plugin_owner_id
        t.string :plugin_policy
        t.string :retained_value
      end
      connection.execute("INSERT INTO plugin_purge_hosts (plugin_owner_id, plugin_policy, retained_value) VALUES (42, 'active', 'remove')")
      connection.execute("INSERT INTO plugin_purge_hosts (plugin_owner_id, plugin_policy, retained_value) VALUES (NULL, NULL, 'keep')")
      purge = described_class.new("no_such_plugin")
      allow(purge).to receive(:inline_field_configuration).and_return(
        "plugin_purge_hosts" => {
          "delete_rows_where_present" => "plugin_owner_id",
          "drop_columns" => %w[plugin_owner_id plugin_policy]
        }
      )

      expect(purge.purge!).to include("plugin_purge_hosts.plugin_owner_id", "plugin_purge_hosts.plugin_policy")
      expect(connection.column_exists?(:plugin_purge_hosts, :plugin_owner_id)).to be(false)
      expect(connection.column_exists?(:plugin_purge_hosts, :plugin_policy)).to be(false)
      expect(connection.select_values("SELECT retained_value FROM plugin_purge_hosts")).to eq([ "keep" ])
    ensure
      connection&.drop_table(:plugin_purge_hosts, if_exists: true)
    end
  end

  describe "purge contributors", :reset_plugin_registry do
    around do |example|
      Syrus::PluginRegistry.reset!
      example.run
      Syrus::PluginRegistry.reset!
    end

    let(:contributor) do
      Class.new do
        include Syrus::Plugin::PurgeContributor

        class_attribute :purged, default: []
        def self.purge_report(plugin_name) = plugin_name == "gone_plugin" ? [ "volume gone_plugin_data (4 KB)" ] : []
        def self.purge!(plugin_name) = (self.purged += [ plugin_name ]) && [ "volume gone_plugin_data" ]
      end
    end

    # A container-backed plugin's volumes are its data too; a purge that
    # dropped only tables would leave them behind.
    it "lists and removes what contributors hold for the plugin" do
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "runtime_like", version: "1.0.0", provides: { purge_contributor: contributor })
      purge = described_class.new("gone_plugin")

      expect(purge.report).to have_attributes(other_data: [ "volume gone_plugin_data (4 KB)" ], empty?: false)
      expect(purge.purge!).to include("volume gone_plugin_data")
      expect(contributor.purged).to eq([ "gone_plugin" ])
    end

    it "reports a contributor that cannot answer instead of hiding its data" do
      broken = Class.new do
        include Syrus::Plugin::PurgeContributor

        def self.purge_report(_) = raise("manager unreachable")
        def self.to_s = "BrokenContributor"
      end
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "broken_runtime", version: "1.0.0", provides: { purge_contributor: broken })

      expect(described_class.new("gone_plugin").report.other_data.sole).to match(/BrokenContributor: could not report .*manager unreachable/)
    end
  end
end
