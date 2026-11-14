# Spec files that a given grader failed on the previous loop iteration.
#
# Repair loops re-ran the entire suite after every fix, so a repair that did
# not work still cost a full grading pass before anyone found out -- on this
# repository that is ~38 minutes for rspec, and a production train spent three
# iterations doing exactly that. The failing set from the previous iteration is
# already recorded, so a grader can check the known-bad specs first and reject
# a failed repair in seconds.
#
# This is deliberately only usable as a fail-fast gate. A narrowed pass does
# not prove the suite is green -- the repair's own edits can break specs that
# were not in the failing set, and the change-to-spec mapping in this codebase
# is a heuristic, not an impact analysis. So the full suite must still run
# behind the gate and still decide the verdict.
class PreviousGraderFailures
  def self.spec_paths_for(step) = new(step).spec_paths

  def initialize(step)
    @step = step
  end

  def spec_paths
    return [] unless step&.loop_id.present?
    return [] unless step.iteration.to_i > 1

    previous_steps.each do |previous_step|
      run = previous_step.latest_run
      next unless run

      paths = TestEvidenceLookup
        .failed_test_cases_for(run, previous_step.details.to_h["name"])
        .filter_map { |test_case| test_case["file_path"].to_s.presence }
        .uniq
        .sort
      return paths if paths.any?
    end
    []
  end

  private

  attr_reader :step

  def grader_name
    step.details.to_h["name"].to_s
  end

  # Walk past carried/deduplicated iterations to the latest persisted failing
  # evidence. A CI-suffixed variant is equivalent only when its command and
  # target fingerprints are also identical; phase-specific commands remain
  # genuinely distinct graders.
  def previous_steps
    @previous_steps ||= step.workflow.steps
      .where(kind: step.kind, loop_id: step.loop_id)
      .where("iteration < ?", step.iteration.to_i)
      .order(iteration: :desc, position: :desc)
      .select { |candidate| equivalent_grader?(candidate) }
  end

  def equivalent_grader?(candidate)
    details = candidate.details.to_h
    current = step.details.to_h
    return true if details["name"].to_s == grader_name
    return false unless normalized_name(details["name"]) == normalized_name(grader_name)
    return false unless details["command"].to_s == current["command"].to_s

    details["target_fingerprints"].to_h == current["target_fingerprints"].to_h
  end

  def normalized_name(name)
    name.to_s.downcase.sub(/-ci\z/, "").sub(/\Aci-/, "")
  end
end
