class DataRootDiskUsageRefreshJob < ApplicationJob
  queue_as :default

  def perform
    DataRootDiskUsage.refresh!
  end
end
