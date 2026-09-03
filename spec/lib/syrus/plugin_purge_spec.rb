require "rails_helper"

RSpec.describe Syrus::PluginPurge do
  describe "#report" do
    it "lists the tables a bundled plugin's models declare" do
      report = described_class.new("build_cache").report

      expect(report.tables).to eq([ "build_cache_clear_requests" ])
      expect(report.row_counts).to have_key("build_cache_clear_requests")
    end

    it "counts existing rows" do
      ENV["SCCACHE_BUCKET"] = "spec-bucket"
      BuildCache::ClearRequest.create!(scope: "full", reason: "spec", user: Factories.user)

      expect(described_class.new("build_cache").report.total_rows).to eq(1)
    ensure
      ENV.delete("SCCACHE_BUCKET")
    end

    it "reports nothing for a plugin that owns no tables" do
      expect(described_class.new("throughput").report).to be_empty
    end

    it "reports nothing for a plugin that was never installed" do
      expect(described_class.new("no_such_plugin").report).to be_empty
    end
  end

  describe "#purge!" do
    it "refuses while the plugin is still installed" do
      expect { described_class.new("build_cache").purge! }
        .to raise_error(described_class::PluginStillInstalled, /still installed/)
    end

    it "never claims a core table even if a plugin migration names one" do
      purge = described_class.new("build_cache")
      allow(purge).to receive(:migration_tables).and_return([ "jobs", "users" ])

      expect(purge.tables).not_to include("jobs", "users")
    end

    it "drops the plugin's tables and its PluginRecord row when forced" do
      PluginRecord.find_or_create_by!(name: "build_cache")

      dropped = described_class.new("build_cache").purge!(force: true)

      expect(dropped).to eq([ "build_cache_clear_requests" ])
      expect(ActiveRecord::Base.connection.table_exists?("build_cache_clear_requests")).to be(false)
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
      end
    end
  end
end
