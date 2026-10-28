class RetentionSweepJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    RetentionPolicyPruneJob.perform_later_missing_simple_args(
      RetentionPolicyRegistry.definitions.map { |definition| [ definition.key.to_s ] }
    )
  end
end
