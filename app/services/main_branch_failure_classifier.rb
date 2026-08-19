class MainBranchFailureClassifier
  Result = Data.define(:inherited, :evidence, :inherited_names, :new_names) do
    def inherited? = inherited
  end

  def self.call(workflow:, failed_grader_steps:)
    new(workflow: workflow, failed_grader_steps: failed_grader_steps).call
  end

  def initialize(workflow:, failed_grader_steps:)
    @workflow = workflow
    @failed_grader_steps = Array(failed_grader_steps)
    @repository = workflow.job.repository
  end

  def call
    return no_match unless AppSetting.isolate_unrelated_main_branch_failures?
    return no_match if @failed_grader_steps.empty?
    return no_match if infrastructure_workflow?
    return no_match unless @repository.main_branch_health_enabled?
    return no_match unless @repository.main_health_broken?

    evidence = latest_broken_grader_evidence
    return no_match unless evidence

    failed_names = @failed_grader_steps.map { |step| step.details.to_h["name"].to_s }.reject(&:blank?)
    inherited_names = failed_names & evidence.fetch("failed_names")
    new_names = failed_names - evidence.fetch("failed_names")

    Result.new(
      inherited: failed_names.any? && new_names.empty?,
      evidence: evidence,
      inherited_names: inherited_names,
      new_names: new_names
    )
  end

  private

  def no_match
    Result.new(inherited: false, evidence: nil, inherited_names: [], new_names: [])
  end

  def infrastructure_workflow?
    @workflow.infrastructure_workflow? || MainHealthChangedService.fix_main_job?(@workflow.job)
  end

  def latest_broken_grader_evidence
    check = MainBranchHealthCheck
      .where(repository: @repository, grader_health: "broken")
      .where.not(grader_failed_names: [ nil, [] ])
      .recent
      .first
    return nil unless check

    names = Array(check.grader_failed_names).map(&:to_s).reject(&:blank?)
    return nil if names.empty?

    {
      "health_check_id" => check.id,
      "sha" => check.sha,
      "checked_at" => check.checked_at&.iso8601,
      "source" => check.source,
      "workflow_id" => check.workflow_id,
      "failed_names" => names
    }
  end
end
