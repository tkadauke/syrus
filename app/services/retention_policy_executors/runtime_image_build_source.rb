module RetentionPolicyExecutors
  class RuntimeImageBuildSource < Default
    def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
      window = @definition.retention_window
      return Result.new(deleted_count: 0, backlog: false) unless window

      scope = RuntimeImageBuildRequest.terminal.where(finished_at: ..(Time.current - window))
        .joins(:source_archive_attachment)
      purged = 0
      max_batches.times do
        rows = scope.limit(batch_size).to_a
        break if rows.empty?
        rows.each { |request| request.source_archive.purge }
        purged += rows.size
      end
      Result.new(deleted_count: purged, backlog: scope.exists?)
    end
  end
end
