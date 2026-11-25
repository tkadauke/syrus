# Executes one build attempt for a runtime image build request. Runs on the
# dedicated runtime_image_builds queue so builds never share threads with
# control-plane work. The request must already be claimed by the dispatcher;
# if it is not (cancelled, retried elsewhere) the job is a no-op.
class RuntimeImageBuildJob < ApplicationJob
  queue_as :runtime_image_builds

  # request_id/attempt_id come from RuntimeImages::Builds::Orchestrator#claim.
  def perform(request_id, attempt_id)
    attempt = RuntimeImageBuildAttempt.find_by(id: attempt_id, runtime_image_build_request_id: request_id)
    return unless attempt&.active?
    # A duplicate delivery of the same attempt must not run the build twice.
    return unless RuntimeImages::Builds::Orchestrator.new.begin_execution(attempt)

    RuntimeImages::Builds::Runner.new.call(attempt.request, attempt)
  end
end
