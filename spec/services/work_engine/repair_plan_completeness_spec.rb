require "rails_helper"

# Guards WorkEngine::RepairPlanner and WorkEngine::RepairExecutor against
# drifting apart. A RepairPlanner::Policies subclass that names an
# auto-executable action with no matching RepairExecutor::Policies subclass
# silently resolves to RepairExecutor::Policies::Default (a no-op) in
# production, with nothing to catch it: the reconciler reports "applied" work
# that never actually happened. Static source scanning (rather than driving
# every policy's branchy `#plan` through real Job/Workflow/Run state) keeps
# this spec a cheap, exhaustive tripwire for that drift: any new
# `automatic_plan("some_action", ...)` call added to RepairPlanner without a
# matching RepairExecutor policy class fails this spec immediately.
RSpec.describe "WorkEngine repair plan completeness" do
  AUTOMATIC_ACTIONS = File.read(Rails.root.join("app/services/work_engine/repair_planner.rb"))
    .scan(/automatic_plan\(\s*\n?\s*"([a-z_]+)"/)
    .flatten
    .uniq
    .freeze

  it "has automatic actions to check (guards against the scan silently matching nothing)" do
    expect(AUTOMATIC_ACTIONS.size).to be >= 40
  end

  it "resolves every RepairPlanner automatic action to a real RepairExecutor policy, not the Default no-op" do
    missing = AUTOMATIC_ACTIONS.reject do |action|
      WorkEngine::RepairExecutor::Policies::Base.for(action) != WorkEngine::RepairExecutor::Policies::Default
    end

    expect(missing).to be_empty,
      "these RepairPlanner actions fall through to the RepairExecutor::Policies::Default no-op: #{missing.inspect}"
  end

  it "gives every non-Default RepairExecutor policy a distinct action name" do
    classes = WorkEngine::RepairExecutor::Policies::Base.descendants - [ WorkEngine::RepairExecutor::Policies::Default ]

    expect(classes.map(&:action).uniq.size).to eq(classes.size)
  end
end
