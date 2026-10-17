# Deletes retention-backed rows in bounded, stable primary-key batches.
# Each batch is its own transaction so an optional archive and the matching
# delete describe exactly the same set of records.
class RetentionPruner
  DEFAULT_BATCH_SIZE = 1_000
  DEFAULT_MAX_BATCHES = 50
  FALLBACK_BATCH_LOCK = Mutex.new

  def self.call(scope:, retention_key: nil, cutoff: nil, batch_size: DEFAULT_BATCH_SIZE, max_batches: DEFAULT_MAX_BATCHES)
    new(
      scope: scope,
      retention_key: retention_key,
      cutoff: cutoff,
      batch_size: batch_size,
      max_batches: max_batches
    ).call
  end

  def initialize(scope:, retention_key:, cutoff:, batch_size:, max_batches:)
    @scope = scope
    @retention_key = retention_key
    @cutoff = cutoff
    @batch_size = batch_size
    @max_batches = max_batches
  end

  def call
    deleted = 0

    @max_batches.times do
      batch_deleted = prune_batch || 0
      break if batch_deleted.zero?

      deleted += batch_deleted
    end

    deleted
  end

  private

  def prune_batch
    synchronize_batch do
      model.transaction do
        ids = candidate_scope.pluck(primary_key)
        next 0 if ids.empty?

        batch_scope = model.where(primary_key => ids)
        archive(batch_scope) if @retention_key
        batch_scope.delete_all
      end
    end
  end

  def synchronize_batch(&block)
    return yield if skip_locked?

    FALLBACK_BATCH_LOCK.synchronize(&block)
  end

  def candidate_scope
    candidates = @scope.reorder(primary_key => :asc).limit(@batch_size)
    skip_locked? ? candidates.lock("FOR UPDATE SKIP LOCKED") : candidates
  end

  # Syrus production uses MySQL, where row claims must coordinate across
  # processes. SQLite ignores SELECT locks, so tests and development serialize
  # batch selection within the process instead.
  def skip_locked? = model.connection.adapter_name.casecmp?("Mysql2")

  def archive(batch_scope)
    RetentionArchiver.call(retention_key: @retention_key, scope: batch_scope, cutoff: @cutoff)
  end

  def model = @scope.klass
  def primary_key = model.primary_key
end
