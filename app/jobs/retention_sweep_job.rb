class RetentionSweepJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    definitions = RetentionPolicyRegistry.definitions
    settings = RetentionPolicySetting.for_definitions(definitions)
    RetentionPolicyPruneJob.perform_later_missing_simple_args(
      definitions.filter_map do |definition|
        key = definition.key.to_s
        [ key, false ] unless settings.fetch(key).archive_before_delete?
      end
    )
  end
end
