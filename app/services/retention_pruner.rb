# Deletes retention-backed rows in bounded, stable primary-key batches.
# Each batch is its own transaction so an optional archive and the matching
# delete describe exactly the same set of records.
class RetentionPruner
  DEFAULT_BATCH_SIZE = 1_000
  DEFAULT_MAX_BATCHES = 50

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
    model.transaction do
      ids = @scope.reorder(primary_key => :asc).limit(@batch_size).pluck(primary_key)
      next 0 if ids.empty?

      batch_scope = model.where(primary_key => ids)
      archive(batch_scope) if @retention_key
      batch_scope.delete_all
    end
  end

  def archive(batch_scope)
    RetentionArchiver.call(retention_key: @retention_key, scope: batch_scope, cutoff: @cutoff)
  end

  def model = @scope.klass
  def primary_key = model.primary_key
end
