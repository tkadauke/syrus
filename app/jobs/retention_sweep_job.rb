class RetentionSweepJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    RetentionPolicyPruneJob.perform_later_missing_simple_args(
      RetentionPolicyRegistry.definitions.filter_map do |definition|
        [ definition.key.to_s, false ] unless definition.setting.archive_before_delete?
      end
    )
  end
end
