require "rails_helper"

RSpec.describe RetentionSizeSnapshotJob do
  let(:connection) { ActiveRecord::Base.connection }

  # Real RetentionPolicyRegistry entry (existing "notification" AppSetting
  # column + table) so AppSetting.current.public_send(setting_key) hits a
  # real column instead of a made-up one, without asserting on the full
  # (plugin-extendable) registry list core specs must not enumerate.
  let(:definition) { RetentionPolicyRegistry.fetch(:notification) }

  before do
    allow(RetentionPolicyRegistry).to receive(:definitions).and_return([ definition ])
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  describe "#perform" do
    it "caches row count, byte size, and the projected max byte size for a finite retention window" do
      AppSetting.current.update!(notification_retention_days: 10)
      allow(TableSizeEstimator).to receive(:estimate).with("notifications").and_return(
        TableSizeEstimator::Result.new(table_name: "notifications", row_count_estimate: 1000, byte_size_estimate: 200_000)
      )

      described_class.perform_now

      snapshot = described_class.table_snapshot(:notification)
      expect(snapshot.table_name).to eq("notifications")
      expect(snapshot.row_count_estimate).to eq(1000)
      expect(snapshot.byte_size_estimate).to eq(200_000)
      expect(snapshot.retention_value).to eq(10)
      expect(snapshot.retention_unit).to eq(:days)
      expect(snapshot.bytes_per_unit_estimate).to eq(20_000.0)
      expect(snapshot.estimated_max_byte_size).to eq(200_000)
      expect(snapshot.computed_at).to be_within(5.seconds).of(Time.current)
    end

    it "exposes the projection as unbounded/null when the configured retention is infinite" do
      AppSetting.current.update!(notification_retention_days: 0)
      allow(TableSizeEstimator).to receive(:estimate).and_return(
        TableSizeEstimator::Result.new(table_name: "notifications", row_count_estimate: 1000, byte_size_estimate: 200_000)
      )

      described_class.perform_now

      snapshot = described_class.table_snapshot(:notification)
      expect(snapshot.retention_value).to eq(0)
      expect(snapshot.bytes_per_unit_estimate).to be_nil
      expect(snapshot.estimated_max_byte_size).to be_nil
    end

    it "guards the divide-by-zero case when the table is currently empty" do
      AppSetting.current.update!(notification_retention_days: 10)
      allow(TableSizeEstimator).to receive(:estimate).and_return(
        TableSizeEstimator::Result.new(table_name: "notifications", row_count_estimate: 0, byte_size_estimate: 0)
      )

      described_class.perform_now

      snapshot = described_class.table_snapshot(:notification)
      expect(snapshot.bytes_per_unit_estimate).to be_nil
      expect(snapshot.estimated_max_byte_size).to be_nil
    end
  end

  describe "available-space source labeling" do
    before do
      allow(TableSizeEstimator).to receive(:estimate).and_return(
        TableSizeEstimator::Result.new(table_name: "notifications", row_count_estimate: 0, byte_size_estimate: 0)
      )
    end

    it "prefers a manual override over automatic inference when both are present" do
      AppSetting.current.update!(retention_available_space_override_gb: 50)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYRUS_SQLITE").and_return("1")
      allow(DataRootDiskUsage).to receive(:refresh!)

      described_class.perform_now

      snapshot = described_class.available_space
      expect(snapshot.source).to eq(:manual)
      expect(snapshot.available_bytes).to eq(50.gigabytes)
      expect(DataRootDiskUsage).not_to have_received(:refresh!)
    end

    it "reuses DataRootDiskUsage's disk-usage read for SQLite local mode when no override is set" do
      AppSetting.current.update!(retention_available_space_override_gb: 0)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYRUS_SQLITE").and_return("1")
      usage = DataRootDiskUsage.parse_df(
        "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/pvc 100000000 90000000 10000000 90% /syrus-home\n",
        path: "/data"
      )
      allow(DataRootDiskUsage).to receive(:refresh!).and_return(usage)

      described_class.perform_now

      snapshot = described_class.available_space
      expect(snapshot.source).to eq(:measured)
      expect(snapshot.available_bytes).to eq(10_000_000.kilobytes)
    end

    it "returns nil available bytes and labels unknown when MySQL's datadir isn't locally readable" do
      AppSetting.current.update!(retention_available_space_override_gb: 0)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYRUS_SQLITE").and_return(nil)
      allow(connection).to receive(:adapter_name).and_return("Mysql2")
      allow(connection).to receive(:select_value).with("SELECT @@datadir").and_return("/var/lib/mysql")
      allow(File).to receive(:directory?).with("/var/lib/mysql").and_return(false)

      described_class.perform_now

      snapshot = described_class.available_space
      expect(snapshot.source).to eq(:unknown)
      expect(snapshot.available_bytes).to be_nil
    end

    it "measures a locally-readable MySQL datadir's filesystem when no override is set" do
      AppSetting.current.update!(retention_available_space_override_gb: 0)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYRUS_SQLITE").and_return(nil)
      allow(connection).to receive(:adapter_name).and_return("Mysql2")
      allow(connection).to receive(:select_value).with("SELECT @@datadir").and_return("/var/lib/mysql")
      allow(File).to receive(:directory?).with("/var/lib/mysql").and_return(true)
      allow(Open3).to receive(:capture3).with("df", "-Pk", "/var/lib/mysql").and_return(
        [
          "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda 50000000 40000000 10000000 80% /var/lib/mysql\n",
          "",
          instance_double(Process::Status, success?: true)
        ]
      )

      described_class.perform_now

      snapshot = described_class.available_space
      expect(snapshot.source).to eq(:measured)
      expect(snapshot.available_bytes).to eq(10_000_000.kilobytes)
    end
  end
end
