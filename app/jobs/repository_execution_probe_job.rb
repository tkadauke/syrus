class RepositoryExecutionProbeJob < ApplicationJob
  queue_as :runs

  def perform(probe_id)
    RepositoryExecutionProbeRunner.new(RepositoryExecutionProbe.find(probe_id)).call
  end
end
