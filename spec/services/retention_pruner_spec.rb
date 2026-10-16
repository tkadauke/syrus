require "rails_helper"

RSpec.describe RetentionPruner do
  describe ".call" do
    it "deletes stable primary-key batches up to the per-run cap" do
      user = Factories.user
      notifications = 5.times.map do |index|
        Notification.create!(user: user, kind: "job_failed", body: "Old #{index}", created_at: 31.days.ago)
      end

      deleted = described_class.call(scope: Notification.prunable, batch_size: 2, max_batches: 2)

      expect(deleted).to eq(4)
      expect(Notification.order(:id).pluck(:id)).to eq([ notifications.last.id ])
    end

    it "archives and deletes the same selected IDs when rows change around the cutoff" do
      AppSetting.current.update!(run_diagnostic_archive_before_delete: true)
      selected = RunDiagnostic.create!(run: Factories.run, error_class: "Selected")
      selected.update_columns(created_at: (RunDiagnostic.retention_window + 1.day).ago)
      original_call = RetentionArchiver.method(:call)
      inserted = nil

      allow(RetentionArchiver).to receive(:call) do |**arguments|
        archive = original_call.call(**arguments)
        selected.update_columns(created_at: Time.current)
        inserted = RunDiagnostic.create!(run: Factories.run, error_class: "Inserted")
        inserted.update_columns(created_at: (RunDiagnostic.retention_window + 1.day).ago)
        archive
      end

      deleted = described_class.call(
        scope: RunDiagnostic.prunable,
        retention_key: :run_diagnostic,
        cutoff: RunDiagnostic.retention_cutoff,
        batch_size: 1,
        max_batches: 1
      )

      archived_rows = Zlib::GzipReader.new(StringIO.new(RetentionArchive.last.archive_file.download))
        .read.lines.map { |line| JSON.parse(line) }
      expect(deleted).to eq(1)
      expect(archived_rows.pluck("id")).to eq([ selected.id ])
      expect(RunDiagnostic.exists?(selected.id)).to be(false)
      expect(RunDiagnostic.exists?(inserted.id)).to be(true)
    end

    it "rolls back the archive when the batch cannot complete" do
      AppSetting.current.update!(run_diagnostic_archive_before_delete: true)
      selected = RunDiagnostic.create!(run: Factories.run, error_class: "Selected")
      selected.update_columns(created_at: (RunDiagnostic.retention_window + 1.day).ago)
      original_call = RetentionArchiver.method(:call)

      allow(RetentionArchiver).to receive(:call) do |**arguments|
        original_call.call(**arguments)
        raise ActiveRecord::Rollback
      end

      deleted = described_class.call(
        scope: RunDiagnostic.prunable,
        retention_key: :run_diagnostic,
        cutoff: RunDiagnostic.retention_cutoff,
        batch_size: 1,
        max_batches: 1
      )

      expect(deleted).to eq(0)
      expect(RetentionArchive.count).to eq(0)
      expect(RunDiagnostic.exists?(selected.id)).to be(true)
    end
  end
end
