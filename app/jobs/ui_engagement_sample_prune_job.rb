class UiEngagementSamplePruneJob < ApplicationJob
  queue_as :cleanup

  def perform
    UiEngagementSample.prunable.delete_all
  end
end
