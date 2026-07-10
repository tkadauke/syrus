class MainGraderWorkflowJob < ApplicationJob
  queue_as :default

  # Runs the repository's .syrus.yml graders against the default branch HEAD SHA
  # and updates grader_health accordingly. Implemented in the main_grader workflow job.
  def perform(repository_id, sha)
    # Placeholder — the main_grader workflow step will implement this.
    Rails.logger.info("[MainGraderWorkflowJob] #{repository_id}@#{sha} — grader workflow not yet implemented")
  end
end
