require "rails_helper"

RSpec.describe RetentionArchiver do
  def decompressed_lines(archive)
    Zlib::GzipReader.new(StringIO.new(archive.archive_file.download)).read.lines.map { |line| JSON.parse(line) }
  end

  describe ".call" do
    it "raises for a retention_key that is not archivable" do
      expect {
        described_class.call(retention_key: :notification, scope: Notification.all, cutoff: Time.current)
      }.to raise_error(ArgumentError, /not archivable/)
    end

    it "is a no-op and returns nil when the table's archive_before_delete setting is off (default)" do
      old = RunDiagnostic.create!(run: Factories.run, error_class: "X")
      old.update_columns(created_at: (RunDiagnostic.retention_window + 1.day).ago)

      result = described_class.call(retention_key: :run_diagnostic, scope: RunDiagnostic.prunable, cutoff: RunDiagnostic.retention_cutoff)

      expect(result).to be_nil
      expect(RetentionArchive.count).to eq(0)
      expect(RunDiagnostic.exists?(old.id)).to be true
    end

    it "is a no-op and returns nil when cutoff is nil" do
      AppSetting.current.update!(run_diagnostic_archive_before_delete: true)
      old = RunDiagnostic.create!(run: Factories.run, error_class: "X")
      old.update_columns(created_at: 10.years.ago)

      result = described_class.call(retention_key: :run_diagnostic, scope: RunDiagnostic.all, cutoff: nil)

      expect(result).to be_nil
      expect(RetentionArchive.count).to eq(0)
    end

    it "is a no-op and returns nil when the scope has no rows" do
      AppSetting.current.update!(run_diagnostic_archive_before_delete: true)
      RunDiagnostic.create!(run: Factories.run, error_class: "X") # fresh, not in scope below

      result = described_class.call(retention_key: :run_diagnostic, scope: RunDiagnostic.none, cutoff: Time.current)

      expect(result).to be_nil
      expect(RetentionArchive.count).to eq(0)
    end

    it "archives the scope's rows to a decompressible JSONL attachment, without deleting them" do
      AppSetting.current.update!(run_diagnostic_archive_before_delete: true)
      old_one = RunDiagnostic.create!(run: Factories.run, error_class: "OldOne")
      old_two = RunDiagnostic.create!(run: Factories.run, error_class: "OldTwo")
      [ old_one, old_two ].each { |r| r.update_columns(created_at: (RunDiagnostic.retention_window + 1.day).ago) }
      cutoff = RunDiagnostic.retention_cutoff

      archive = described_class.call(retention_key: :run_diagnostic, scope: RunDiagnostic.prunable, cutoff: cutoff)

      expect(archive).to be_a(RetentionArchive)
      expect(archive.retention_key).to eq("run_diagnostic")
      expect(archive.pruned_before).to be_within(1.second).of(cutoff)
      expect(archive.row_count).to eq(2)
      expect(archive.byte_size).to eq(archive.archive_file.byte_size)
      expect(archive.byte_size).to be > 0

      rows = decompressed_lines(archive)
      expect(rows.map { |row| row["error_class"] }).to contain_exactly("OldOne", "OldTwo")

      # RetentionArchiver only archives; deletion remains the caller's job.
      expect(RunDiagnostic.exists?(old_one.id)).to be true
      expect(RunDiagnostic.exists?(old_two.id)).to be true
    end

    it "batches serialization via find_in_batches instead of loading the whole scope at once" do
      AppSetting.current.update!(run_diagnostic_archive_before_delete: true)
      3.times { |n| RunDiagnostic.create!(run: Factories.run, error_class: "Batch#{n}").update_columns(created_at: (RunDiagnostic.retention_window + 1.day).ago) }
      scope = RunDiagnostic.prunable

      expect(scope).to receive(:find_in_batches).with(batch_size: 2).and_call_original

      archive = described_class.call(retention_key: :run_diagnostic, scope: scope, cutoff: RunDiagnostic.retention_cutoff, batch_size: 2)

      expect(archive.row_count).to eq(3)
    end

    it "creates exactly one RetentionArchive row per call, regardless of batch count" do
      AppSetting.current.update!(run_diagnostic_archive_before_delete: true)
      3.times { RunDiagnostic.create!(run: Factories.run, error_class: "X").update_columns(created_at: (RunDiagnostic.retention_window + 1.day).ago) }

      expect {
        described_class.call(retention_key: :run_diagnostic, scope: RunDiagnostic.prunable, cutoff: RunDiagnostic.retention_cutoff, batch_size: 1)
      }.to change { RetentionArchive.count }.by(1)
    end
  end
end
