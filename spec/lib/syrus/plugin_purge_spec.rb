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
      Syrus::PluginRegistry.register(name: "runtime_like", version: "1.0.0", provides: { purge_contributor: contributor })
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
      Syrus::PluginRegistry.register(name: "broken_runtime", version: "1.0.0", provides: { purge_contributor: broken })

      expect(described_class.new("gone_plugin").report.other_data.sole).to match(/BrokenContributor: could not report .*manager unreachable/)
    end
  end
end
