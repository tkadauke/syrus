# Admission loop for the runtime image build plane: reaps attempts whose lease
# expired, then claims startable requests (within the concurrency caps) and
# hands each to RuntimeImageBuildJob. Does nothing until a builder is
# registered, which keeps the plane dark by default.
class RuntimeImageBuildDispatchJob < ApplicationJob
  include SkipIfPending

  queue_as :control_plane

  def perform
    orchestrator = RuntimeImages::Builds::Orchestrator.new
    reaped = orchestrator.reap_expired.size
    dispatched = 0
    while (claimed = orchestrator.claim_next)
      request, attempt = claimed
      RuntimeImageBuildJob.perform_later(request.id, attempt.id)
      dispatched += 1
    end
    Rails.logger.info("[RuntimeImageBuildDispatchJob] reaped=#{reaped} dispatched=#{dispatched}") if reaped.positive? || dispatched.positive?
    dispatched
  end
end
