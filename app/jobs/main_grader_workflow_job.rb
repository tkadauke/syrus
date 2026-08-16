class MainGraderWorkflowJob < ApplicationJob
  queue_as :control_plane

  limits_concurrency to: 1, key: ->(repo_id, *) { "main_grader:#{repo_id}" }

  # Creates a main_grader Job + Workflow that runs .syrus.yml graders against
  # the given SHA on the repository's default branch.
  #
  # At most one active grading workflow is allowed per repository. If another
  # is already running (for any SHA), this is a no-op — the poll job will
  # re-trigger for the latest SHA once the active one finishes. The repository's
  # last_graded_sha advances only after the workflow records a settled result.
  def perform(repository_id, sha)
    repository = Repository.find_by(id: repository_id)
    return unless repository
    return if repository.archived?
    return if MainBranchHealthCheck.conclusive_grader_result_exists?(repository: repository, sha: sha)
    return if active_grading_workflow?(repository) || active_main_branch_repair_workflow?(repository)

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

  def active_grading_workflow?(repository)
    Job.where(
      repository: repository,
      kind: "main_grader"
    ).where.not(state: "closed").exists?
  end

  def active_main_branch_repair_workflow?(repository)
    Job.where(
      repository: repository,
      system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR
    ).where.not(state: "closed").exists?
  end
end
