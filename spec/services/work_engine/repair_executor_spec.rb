require "rails_helper"

RSpec.describe WorkEngine::RepairExecutor do
  RepairResult = Data.define(:repair_plans)

  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }

  def repair_plan(action:, target:)
    WorkEngine::RepairPlanner::Plan.new(
      issue_kind: "running_workflow_without_active_descendants",
      action: action,
      auto_executable: true,
      target_type: target.class.name,
      target_id: target.id,
      affected_ids: {},
      execution_steps: [],
      preconditions: {},
      reason: "test"
    )
  end

  it "fails a running workflow with an uncleared retry barrier instead of marking it succeeded" do
    workflow.steps.destroy_all
    loop_id = SecureRandom.uuid
    fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 1, loop_id: loop_id, state: "succeeded", finished_at: 5.minutes.ago)
    collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 2, loop_id: loop_id, state: "cancelled", finished_at: 4.minutes.ago)
    fanout.update!(next_step: collect)
    workflow.update_columns(state: "running", started_at: 10.minutes.ago, finished_at: nil)

    result = described_class.call(
      result: RepairResult.new([
        repair_plan(action: "finish_workflow_from_terminal_descendants", target: workflow)
      ])
    )

    expect(result.first).to have_attributes(status: "applied")
    expect(result.first.message).to include("marked #{workflow.slug} failed")
    expect(workflow.reload).to be_failed
  end
end
