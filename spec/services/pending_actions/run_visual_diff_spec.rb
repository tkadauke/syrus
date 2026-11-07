require "rails_helper"

RSpec.describe PendingActions::RunVisualDiff do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  before do
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
      RepoVisualReviewPlan::Result.new(enabled: true, rounds: 1, source: ".syrus.yml", note: nil)
    )
  end

  def add_after_screenshot(job, artifact: nil)
    artifact ||= {
      "type" => "visual_review_screenshot_run_1_1", "title" => "Dashboard",
      "image_url" => "/api/v1/app/workflows/10/visual_artifact?type=visual_review_screenshot_run_1_1",
      "content_type" => "image/png"
    }
    Workflow.create!(job: job, trigger_kind: "manual_visual_review", state: "succeeded", artifacts: {
      "visual_review_iterations" => [ { "iteration" => 1, "verdict" => "approved", "artifacts" => [ artifact ] } ]
    })
  end

  def pending_action(job)
    chat_session.pending_actions.create!(action: "run_visual_diff", payload: { "job_id" => job.id }, requested_by: "agent")
  end

  it "dispatches visual_diff at confirmation and stores the Workflow result" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    add_after_screenshot(job)
    action = pending_action(job)

    expect { action.confirm!(user: user) }.to have_enqueued_job(RunJob)

    expect(action.reload).to be_confirmed
    expect(action.result).to have_attributes(trigger_kind: "visual_diff")
    expect(action.result.trigger_kind).not_to eq("manual_visual_review")
  end

  it "validates eligibility again at confirmation time" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    add_after_screenshot(job)
    action = pending_action(job)
    job.update!(state: "running")

    expect { action.confirm!(user: user) }.to raise_error(ArgumentError, /implemented, approved, or landing/)
    expect(job.workflows.where(trigger_kind: "visual_diff")).to be_empty
  end

  it "reports missing and invalid prior screenshots without creating a workflow" do
    missing_job = Factories.job_record(user: user, repository: repository, state: "implemented")
    expect { pending_action(missing_job).confirm!(user: user) }.to raise_error(ArgumentError, /No visual review screenshots/)

    invalid_job = Factories.job_record(user: user, repository: repository, state: "implemented", issue_title: "Polish dashboard", issue_body: "The changed surface is /dashboard.")
    add_after_screenshot(invalid_job, artifact: {
      "type" => "visual_review_screenshot_run_1_1", "title" => "Sign in",
      "image_url" => "/visual-artifact/sign-in.png", "content_type" => "image/png",
      "page" => { "path" => "/session/new", "title" => "Sign in" }
    })

    expect { pending_action(invalid_job).confirm!(user: user) }.to raise_error(ArgumentError, /No usable visual review screenshots/)
    expect(Workflow.where(job_id: [ missing_job.id, invalid_job.id ], trigger_kind: "visual_diff")).to be_empty
  end

  it "validates the payload and authorizes the Job" do
    expect {
      chat_session.pending_actions.create!(action: "run_visual_diff", payload: {}, requested_by: "agent")
    }.to raise_error(ActiveRecord::RecordInvalid, /job_id is required/)

    other_user = Factories.user
    other_job = Factories.job_record(user: other_user, repository: Factories.repository(user: other_user), state: "implemented")
    expect { pending_action(other_job).confirm!(user: user) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "serializes a completed comparison using the typed artifact payload" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    add_after_screenshot(job)
    action = pending_action(job)
    action.confirm!(user: user)
    workflow = action.reload.result
    comparison = {
      "type" => "visual_diff_comparison", "title" => "Before/after visual comparison",
      "renderer_type" => "before_after_visual_diff", "payload" => { "pairs" => [] }
    }
    workflow.set_artifact!("typed_artifacts", [ comparison ])

    expect(described_class.new(action.reload).tool_card_outcome).to eq(
      workflow_id: workflow.id, job_id: job.id, comparison: comparison
    )
  end
end
