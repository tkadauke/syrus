require "rails_helper"

RSpec.describe "Browser comparison repair integration" do
  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin) }

  def pending_action_for(job, event)
    ChatSession.create!(user: admin, repository: repository).pending_actions.create!(
      action: "force_state_transition", requested_by: "agent", reason: "operator repair",
      payload: { "job_id" => job.id, "event" => event }
    )
  end

  it "does not duplicate a succeeded automatic comparison when repair returns the Job to implemented" do
    stub_workflow_judge(step_kind: "visual_review")
    job = Factories.job_record(state: "implemented", repository:, user: admin)
    source = Workflow.create!(job:, trigger_kind: "initial", state: "succeeded", artifacts: {
      "visual_review_iterations" => [ { "iteration" => 1, "verdict" => "approved", "artifacts" => [ {
        "type" => "visual_review_screenshot_run_1_1", "title" => "Dashboard",
        "image_url" => "/api/v1/app/workflows/10/visual_artifact?type=visual_review_screenshot_run_1_1"
      } ] } ]
    })
    comparison = VisualDiffSubmission.enqueue_deferred_for_visual_review(source).workflow
    Run.where(step_id: comparison.steps.select(:id)).update_all(state: "succeeded", finished_at: Time.current)
    comparison.update_columns(state: "succeeded", finished_at: Time.current)
    comparison.work_unit.mark_terminal!("succeeded")

    pending_action_for(job, "force_fail").confirm!(user: admin)
    pending_action_for(job, "retry_after_failure").confirm!(user: admin)

    expect { pending_action_for(job, "mark_implemented").confirm!(user: admin) }
      .not_to change { job.workflows.where(trigger_kind: "visual_diff").count }
    expect(job.reload).to be_implemented
  end
end
