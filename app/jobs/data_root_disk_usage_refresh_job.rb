class DataRootDiskUsageRefreshJob < ApplicationJob
  queue_as :cleanup

  def perform
    DataRootDiskUsage.refresh!
  end
end
