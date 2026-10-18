module SearchIndexWriteLimits
  MAX_BATCH_ROWS = 250
  MAX_BATCH_BYTES = 1.megabyte
  MAX_ROW_BYTES = 512.kilobytes

  # Measured 2026-10-18: 100 recent retained operational events had p99
  # message+context size 330 bytes (the ingest hard limits are 4 KB + 8 KB),
  # and all 30 retained design docs had a 49 KB maximum. A 1 MB batch and
  # 512 KB row ceiling leave >10x headroom over those documents while bounding
  # SQLite bind/FTS copies. Oversized rows remain searchable by a visible prefix
  # and emit a warning rather than silently disappearing from search.
  def self.prefix(value, limit: MAX_ROW_BYTES, index:, record_id:, field:)
    text = value.to_s
    return text if text.bytesize <= limit

    Rails.logger.warn(
      "Search index text truncated index=#{index} record_id=#{record_id} field=#{field} " \
      "bytes=#{text.bytesize} limit=#{limit}"
    )
    text.safe_byteslice(0, limit)
  end

  def self.batches(records, max_rows: MAX_BATCH_ROWS, max_bytes: MAX_BATCH_BYTES, &size)
    Enumerator.new do |batches|
      batch = []
      bytes = 0

      records.each do |record|
        record_bytes = size.call(record)
        if batch.any? && (batch.length >= max_rows || bytes + record_bytes > max_bytes)
          batches << batch
          batch = []
          bytes = 0
        end
        batch << record
        bytes += record_bytes
      end

      batches << batch if batch.any?
    end
  end

  def self.clamp_rows(value)
    [ [ value.to_i, 1 ].max, MAX_BATCH_ROWS ].min
  end
end
