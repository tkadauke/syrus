module ConnectedAccounts
  class RefreshSchedulerJob < ApplicationJob
    queue_as :low_priority_maintenance
    def perform = Account.due_for_refresh.find_each { |account| RefreshJob.perform_later(account.id) }
  end
end
