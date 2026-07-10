class MainGraderWorkflowJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(repo_id, sha) { "main_grader:#{repo_id}:#{sha}" }

  # Creates a main_grader Job + Workflow that runs .syrus.yml graders against
  # the given SHA on the repository's default branch.
  #
  # Idempotency: SolidQueue's limits_concurrency prevents two runs for the
  # same repo+sha from overlapping. Additionally, a DB check skips creation
  # when an open main_grader Job already exists for this repository and SHA
  # (stored in issue_title for queryability without a new column).
  def perform(repository_id, sha)
    repository = Repository.find_by(id: repository_id)
    return unless repository
    return if repository.archived?
    return if active_workflow_for_sha?(repository, sha)

    user = repository.user
    return unless user

    Job.transaction do
      job = Job.create!(
        user: user,
        repository: repository,
        kind: "main_grader",
        issue_title: "main_grader:#{sha}",
        issue_number: nil
      )

      workflow = Workflows::MainGrader.instantiate(
        job: job,
        artifacts: { "main_sha" => sha }
      )

      StepDispatcher.start_workflow(workflow)
    end
  end

  private

  # Returns true if there is already an open main_grader Job for this
  # repository grading the same SHA. issue_title carries the SHA so we
  # can check without JSON querying workflow artifacts.
  def active_workflow_for_sha?(repository, sha)
    Job.where(
      repository: repository,
      kind: "main_grader",
      issue_title: "main_grader:#{sha}"
    ).where.not(state: "closed").exists?
  end
end
