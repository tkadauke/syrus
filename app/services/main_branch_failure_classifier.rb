require "digest"

class MainBranchFailureClassifier
  ALLOW_INHERITED = "allow_inherited".freeze
  FAILURE_STATUSES = %w[failed error].freeze

  Result = Data.define(:inherited, :evidence, :inherited_names, :new_names, :classifications) do
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
    return no_match if @failed_grader_steps.empty?
    return no_match if infrastructure_workflow?
    return no_match unless @repository.main_branch_health_enabled?
    return no_match unless @repository.main_health_broken?

    base_sha = landing_unit_base_sha
    return no_match if base_sha.blank?

    evidence = broken_grader_evidence(base_sha)
    return no_match unless evidence

    classifications = @failed_grader_steps.map { |grader_step| classify_step(grader_step, evidence) }
    inherited = classifications.select { |classification| classification.fetch("inherited") }
    introduced = classifications.reject { |classification| classification.fetch("inherited") }

    Result.new(
      inherited: classifications.any? && introduced.empty?,
      evidence: evidence,
      inherited_names: inherited.map { |classification| classification.fetch("name") },
      new_names: introduced.map { |classification| classification.fetch("name") },
      classifications: classifications
    )
  end

  private

  def no_match
    Result.new(inherited: false, evidence: nil, inherited_names: [], new_names: [], classifications: [])
  end

  def infrastructure_workflow?
    @workflow.infrastructure_workflow? || MainHealthChangedService.fix_main_job?(@workflow.job)
  end

  def broken_grader_evidence(base_sha)
    check = MainBranchHealthCheck
      .where(repository: @repository, sha: base_sha, grader_health: "broken")
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

  def landing_unit_base_sha
    case @workflow.trigger_kind
    when "auto_merge"
      @workflow.job.mergeability_base_sha.presence
    when "merge_train"
      @workflow.artifact("merge_train_base_sha").presence
    when "landing_validation", "merge_train_validation"
      @workflow.artifact("predicted_base_sha").presence
    else
      @repository.last_health_checked_sha.presence
    end
  end

  def classify_step(grader_step, evidence)
    details = grader_step.details.to_h
    name = details["name"].to_s
    failures = failure_policy(details)

    base_conclusion = latest_base_conclusion(name, evidence.fetch("sha"))
    base_failed = evidence.fetch("failed_names").include?(name) && base_conclusion&.status == "failed"

    result = {
      "name" => name,
      "failures" => failures,
      "inherited" => false,
      "reason" => "no_matching_base_failure",
      "base_grader_conclusion_id" => base_conclusion&.id,
      "candidate_step_id" => grader_step.id
    }.compact

    return result.merge("reason" => "strict_failure_policy") unless failures == ALLOW_INHERITED
    return result unless base_failed

    if test_case_evidence_present?(grader_step, base_conclusion, name)
      classify_test_cases(result, grader_step, base_conclusion)
    else
      classify_binary_contextual(result, details, base_conclusion)
    end
  end

  def failure_policy(details)
    value = details["failures"].to_s.presence
    return value if value.in?(SyrusYml::GRADE_FAILURE_POLICIES)

    SyrusYml::DEFAULT_GRADE_FAILURE_POLICY
  end

  def latest_base_conclusion(grader_name, base_sha)
    GraderConclusion
      .where(repository: @repository, commit_sha: base_sha, grader_name: grader_name, status: "failed")
      .latest_first
      .first
  end

  def classify_test_cases(result, candidate_step, base_conclusion)
    candidate_run = candidate_step.runs.order(:created_at).last
    candidate_failures = failed_test_identities_for_run(candidate_run, result.fetch("name"))
    base_failures = failed_test_identities_for_run(base_conclusion&.run, result.fetch("name"))

    return result.merge("reason" => "missing_candidate_test_cases") if candidate_failures.empty?
    return result.merge("reason" => "missing_base_test_cases") if base_failures.empty?

    introduced = candidate_failures - base_failures
    inherited = introduced.empty?
    result.merge(
      "inherited" => inherited,
      "reason" => inherited ? "failed_cases_match_base" : "introduced_failed_cases",
      "candidate_failed_case_count" => candidate_failures.size,
      "base_failed_case_count" => base_failures.size,
      "introduced_failed_cases" => introduced.first(20)
    )
  end

  def test_case_evidence_present?(candidate_step, base_conclusion, grader_name)
    candidate_run = candidate_step.runs.order(:created_at).last
    test_case_count_for_run(candidate_run, grader_name).positive? ||
      test_case_count_for_run(base_conclusion&.run, grader_name).positive?
  end

  def test_case_count_for_run(run, grader_name)
    return 0 unless run

    TestCase
      .joins(:test_run)
      .where(test_runs: { run_id: run.id, grader_name: grader_name })
      .count
  end

  def failed_test_identities_for_run(run, grader_name)
    return [] unless run

    TestCase
      .joins(:test_run)
      .where(test_runs: { run_id: run.id, grader_name: grader_name }, status: FAILURE_STATUSES)
      .pluck(:suite_name, :name)
      .map { |suite_name, name| "#{suite_name}\u0000#{name}" }
      .uniq
      .sort
  end

  def classify_binary_contextual(result, details, base_conclusion)
    candidate_fingerprint = output_fingerprint(details["output"])
    base_fingerprint = output_fingerprint(base_conclusion&.step&.details.to_h["output"])

    return result.merge("reason" => "missing_output_fingerprint") if candidate_fingerprint.blank? || base_fingerprint.blank?

    inherited = candidate_fingerprint == base_fingerprint
    result.merge(
      "inherited" => inherited,
      "reason" => inherited ? "output_fingerprint_matches_base" : "output_fingerprint_differs_from_base",
      "candidate_output_fingerprint" => candidate_fingerprint,
      "base_output_fingerprint" => base_fingerprint
    )
  end

  def output_fingerprint(output)
    normalized = output.to_s
      .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
      .gsub(/\e\[[0-9;]*m/, "")
      .gsub(%r{/[^\s:]+/}, "/…/")
      .gsub(/\b0x[0-9a-f]+\b/i, "0x…")
      .gsub(/\b\d+\.\d+s\b/, "N.Ns")
      .gsub(/\s+/, " ")
      .strip
    return nil if normalized.blank?

    Digest::SHA256.hexdigest(normalized)
  end
end
