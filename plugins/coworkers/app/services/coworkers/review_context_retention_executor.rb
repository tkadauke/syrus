class Coworkers::ReviewContextRetentionExecutor < Syrus::Host::RetentionPolicyExecutorsDefault
  def call(batch_size: Syrus::Host::RetentionPrunerDefaultBatchSize, max_batches: Syrus::Host::RetentionPrunerDefaultMaxBatches)
    window = @definition.retention_window
    return Syrus::Host::RetentionPolicyExecutorsResult.new(deleted_count: 0, backlog: false) unless window

    scope = @definition.model_class.public_send(@definition.scope_name).where(created_at: ...Time.current - window)
    records = scope.order(:id).limit(batch_size * max_batches).to_a
    records.each do |context|
      Coworkers::ReviewContextContributor.tombstone(context, reason: "retention")
    end
    Syrus::Host::RetentionPolicyExecutorsResult.new(deleted_count: records.size, backlog: scope.exists?)
  end
end
