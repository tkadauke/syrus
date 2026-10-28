class RetentionPolicyPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup
  limits_concurrency to: 1, key: ->(retention_key) { "retention:#{retention_key}" }

  CONTINUATION_DELAY = 1.minute
  DURATION_BUCKETS = [ 0.01, 0.1, 0.5, 1, 5, 15, 60, 300 ].freeze

  Syrus::Metrics.declare do
    counter :retention_rows_pruned_total, tags: %i[retention_key],
            comment: "Rows deleted or payload-cleared by database retention policy"
    histogram :retention_prune_duration_seconds, buckets: DURATION_BUCKETS, tags: %i[retention_key],
              comment: "Duration of a database retention policy pass"
    gauge :retention_prune_backlog, tags: %i[retention_key], comment: "Whether eligible rows remain after a retention pass"
    counter :retention_prune_failures_total, tags: %i[retention_key], comment: "Failed database retention policy passes"
  end

  def perform(retention_key)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    definition = RetentionPolicyRegistry.find(retention_key)
    unless definition
      result = RetentionPolicyExecutors::Result.new(deleted_count: 0, backlog: false)
      record_success(retention_key, result, started_at)
      Rails.logger.info("[RetentionPolicyPruneJob] key=#{retention_key} inactive; skipping")
      return 0
    end

    result = definition.executor.call
    record_success(definition.key, result, started_at)
    self.class.set(wait: CONTINUATION_DELAY).perform_later(definition.key.to_s) if result.backlog
    result.deleted_count
  rescue StandardError
    Syrus::Metrics.counter(:syrus_retention_prune_failures_total).increment(tags: { retention_key: retention_key.to_s })
    raise
  end

  private

  def record_success(key, result, started_at)
    tags = { retention_key: key.to_s }
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    Syrus::Metrics.counter(:syrus_retention_rows_pruned_total).increment(tags: tags, by: result.deleted_count)
    Syrus::Metrics.histogram(:syrus_retention_prune_duration_seconds).observe(duration, tags: tags)
    Syrus::Metrics.gauge(:syrus_retention_prune_backlog).set(result.backlog ? 1 : 0, tags: tags)
    Rails.logger.info(
      "[RetentionPolicyPruneJob] key=#{key} pruned=#{result.deleted_count} " \
      "duration_seconds=#{duration.round(3)} backlog=#{result.backlog}"
    )
  end
end
