# Opt-in path invoked by a PruneJob before it deletes a batch of prunable
# rows. When the table's RetentionPolicyRegistry entry is `archivable` and
# its `<key>_archive_before_delete` AppSetting is on, serializes the scope's
# rows to a gzip-compressed JSONL Active Storage attachment and records
# exactly one RetentionArchive row for the sweep before the caller proceeds
# with its existing delete. No-ops (never touches RetentionArchive or Active
# Storage) when the setting is off, matching the previous delete-only behavior
# exactly — see config/syrus_docs/app_settings.md's "Archive-before-delete
# storage" section.
class RetentionArchiver
  DEFAULT_BATCH_SIZE = 1000

  def self.call(retention_key:, scope:, cutoff:, batch_size: DEFAULT_BATCH_SIZE)
    new(retention_key: retention_key, scope: scope, cutoff: cutoff, batch_size: batch_size).call
  end

  def initialize(retention_key:, scope:, cutoff:, batch_size: DEFAULT_BATCH_SIZE)
    @definition = RetentionPolicyRegistry.fetch(retention_key)
    raise ArgumentError, "#{retention_key} is not archivable" unless @definition.archivable

    @scope = scope
    @cutoff = cutoff
    @batch_size = batch_size
  end

  # Returns the created RetentionArchive, or nil when archiving didn't run
  # (setting off, no cutoff, or nothing prunable this sweep).
  def call
    return nil unless AppSetting.current.public_send(@definition.archive_setting_key)
    return nil if @cutoff.nil?
    return nil if @scope.none?

    archive!
  end

  private

  def archive!
    row_count = 0
    tempfile = Tempfile.new([ "#{@definition.key}-archive-", ".jsonl.gz" ])
    tempfile.binmode

    begin
      gz = Zlib::GzipWriter.new(tempfile)
      begin
        @scope.find_in_batches(batch_size: @batch_size) do |batch|
          batch.each do |record|
            gz.write("#{record.as_json.to_json}\n")
            row_count += 1
          end
        end
      ensure
        gz.finish
      end

      return nil if row_count.zero?

      tempfile.flush
      persist_archive!(row_count, tempfile.path)
    ensure
      tempfile.close
      tempfile.unlink
    end
  end

  def persist_archive!(row_count, path)
    archive = RetentionArchive.new(
      retention_key: @definition.key.to_s,
      pruned_before: @cutoff,
      row_count: row_count,
      byte_size: File.size(path)
    )
    archive.archive_file.attach(
      io: File.open(path, "rb"),
      filename: "#{@definition.key}-#{@cutoff.utc.strftime('%Y%m%d%H%M%S')}.jsonl.gz",
      content_type: "application/gzip"
    )
    archive.save!
    archive
  end
end
