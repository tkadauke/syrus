class Coworkers::BranchRetentionSweepJob < ApplicationJob
  queue_as :cleanup
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform
    remaining = Coworkers::BranchRetentionSweep::MAX_DELETIONS
    Coworkers::Coworker.includes(:owner_user).find_each do |coworker|
      break if remaining.zero?
      deleted = Coworkers::BranchRetentionSweep.call(coworker:, limit: remaining)
      remaining -= deleted
    end
  end
end
