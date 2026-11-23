class Coworkers::BranchRetentionSweepJob < Syrus::Host::PluginJob
  plugin :coworkers

  def perform
    remaining = Coworkers::BranchRetentionSweep::MAX_DELETIONS
    failures = []
    Coworkers::Coworker.includes(:owner_user).find_each do |coworker|
      break if remaining.zero?
      deleted = Coworkers::BranchRetentionSweep.call(coworker:, limit: remaining)
      remaining -= deleted
    rescue StandardError => error
      failures << error
      Rails.logger.warn("[Coworkers::BranchRetentionSweepJob] coworker #{coworker.id} failed: " \
        "#{GitRunner.redact(error.message)}")
    end
    raise failures.first if failures.any?
  end
end
