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
    return [] unless previous_step

    run = previous_step.latest_run
    return [] unless run

    TestEvidenceLookup
      .failed_test_cases_for(run, grader_name)
      .filter_map { |test_case| test_case["file_path"].to_s.presence }
      .uniq
      .sort
  end

  private

  attr_reader :step

  def grader_name
    step.details.to_h["name"].to_s
  end

  # The same grader, one iteration back in the same loop. Matching on name
  # rather than position: fanout can select a different set of graders per
  # iteration, so position is not stable.
  def previous_step
    @previous_step ||= step.workflow.steps
      .where(kind: step.kind, loop_id: step.loop_id, iteration: step.iteration.to_i - 1)
      .find { |candidate| candidate.details.to_h["name"].to_s == grader_name }
  end
end
