class Coworkers::ReviewContextRetentionExecutor < Syrus::Host::RetentionExecutor
  def call(batch_size: Syrus::Host::RetentionLimits.default_batch_size, max_batches: Syrus::Host::RetentionLimits.default_max_batches)
    window = @definition.retention_window
    return Syrus::Host::RetentionResult.new(deleted_count: 0, backlog: false) unless window

    scope = @definition.model_class.public_send(@definition.scope_name).where(created_at: ...Time.current - window)
    records = scope.order(:id).limit(batch_size * max_batches).to_a
    records.each do |context|
      Coworkers::ReviewContextContributor.tombstone(context, reason: "retention")
    end
    Syrus::Host::RetentionResult.new(deleted_count: records.size, backlog: scope.exists?)
  end
end
