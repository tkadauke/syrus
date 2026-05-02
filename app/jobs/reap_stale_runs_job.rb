class ReapStaleRunsJob < ApplicationJob
  queue_as :default

  def perform
    Run.stale.find_each do |run|
      next unless run.may_fail?
      run.agent_outcome = "worker_died"
      run.fail!
      run.save!
      begin
        JobWorkspace.new(run).cleanup
      rescue => e
        Rails.logger.warn "ReapStaleRunsJob: worktree cleanup failed for Run ##{run.id}: #{e.message}"
      end
    end
  end
end
