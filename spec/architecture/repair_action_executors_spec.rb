require "rails_helper"

# Reconciler: every automatic repair action has an executor, and every
# executor is reachable from a plan.
#
# RepairExecutor looks a plan's action up by policy class name and falls back
# to Policies::Default, which only records "no executor policy exists". An
# automatic plan whose action has no policy would therefore be planned,
# skipped and re-planned on every pass without ever repairing anything. The
# other direction is dead code that still carries authority: a policy no
# planner emits keeps its effect (failing landing workflows, cancelling work)
# callable for whatever next names it. RepairPlanner names every action as a
# literal, so the source is the inventory.
RSpec.describe "WorkEngine repair actions" do
  def planner_source = File.read(Rails.root.join("app/services/work_engine/repair_planner.rb"))

  def planned(kind)
    planner_source.scan(/#{kind}\(\s*(?:"(\w+)"|:(\w+))/m).flatten.compact.uniq
  end

  def policies
    WorkEngine::RepairExecutor::Policies::Base.registry.keys - [ "default" ]
  end

  it "plans every automatic action with a literal name" do
    expect(planner_source.scan(/\bautomatic_plan\(/).size - 1).to eq(planner_source.scan(/\bautomatic_plan\(\s*[":]\w+/m).size)
  end

  it "has an executor policy for every automatic action" do
    expect(planned("automatic_plan") - policies).to be_empty
  end

  it "plans every executor policy automatically somewhere" do
    expect(policies - planned("automatic_plan")).to be_empty
  end

  it "falls back to an operator plan, never an automatic one, for an issue kind with no planner policy" do
    # Flagged safe to auto-repair: a missing policy must still not make it automatic.
    issue = WorkEngine::Reconciler::Issue.new(
      kind: "no_such_issue_kind", severity: "warning", evidence: {}, affected_ids: {},
      safe_to_auto_repair: true, recommended_repair_action: "no_such_action", explanation: "spec"
    )
    policy = WorkEngine::RepairPlanner::Policies::Base.for(issue.kind)
    plan = policy.new(issue: issue, result: nil, now: Time.current).plan

    expect(plan.auto_executable).to be(false)
    expect(plan.action).to eq("operator_review_recovery")
  end
end
