require "rails_helper"

RSpec.describe VisualDiffSubmission do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before do
    clear_enqueued_jobs
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
      RepoVisualReviewPlan::Result.new(enabled: true, rounds: 1, source: ".syrus.yml", note: nil)
    )
  end

  def after_workflow_for(job, artifacts: [ after_artifact ], trigger_kind: "manual_visual_review")
    Workflow.create!(
      job: job,
      trigger_kind: trigger_kind,
      state: "succeeded",
      artifacts: {
        "visual_review_iterations" => [
          { "iteration" => 1, "verdict" => "approved", "critique" => "Looks fine.", "artifacts" => artifacts }
        ]
      }
    )
  end

  def after_artifact
    {
      "type" => "visual_review_screenshot_run_1_1",
      "title" => "Dashboard",
      "image_url" => "/api/v1/app/workflows/10/visual_artifact?type=visual_review_screenshot_run_1_1",
      "content_type" => "image/png",
      "byte_size" => 123
    }
  end

  def sign_in_after_artifact
    after_artifact.merge(
      "title" => "Credential Store after change",
      "page" => {
        "path" => "/session/new",
        "title" => "Sign in"
      }
    )
  end

  def run_visual_diff_step(workflow, job)
    step = workflow.steps.find_by(kind: "visual_diff") ||
      Step.create!(workflow: workflow, kind: "visual_diff", position: 1)
    run = step.runs.first ||
      step.runs.create!(job: job, trigger_kind: "visual_diff")

    Steps::VisualDiff.new(run).call
  end

  it "dispatches a manual visual_diff workflow using existing after screenshots" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    after_workflow_for(job)

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(result.workflow).to have_attributes(trigger_kind: "visual_diff", priority: "low")
    expect(result.workflow.work_unit).to have_attributes(kind: "visual_diff")
    expect(result.workflow.artifact("visual_diff_source")).to eq("manual")
    expect(result.workflow.artifact("visual_diff_after_artifacts")).to contain_exactly(include("title" => "Dashboard"))
    expect(result.run).to be_present
  end

  it "skips the full comparison chain instead of accepting sign-in evidence for a non-auth surface" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "implemented",
      issue_title: "Review the Credential Store route",
      issue_body: "The changed surface is Credential Store."
    )
    after_workflow_for(job, artifacts: [ sign_in_after_artifact ])

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(result.workflow.artifact("visual_diff_after_artifacts")).to be_empty
    rejected = result.workflow.artifact("visual_diff_rejected_after_artifacts")
    expect(rejected).to contain_exactly(include(
      "title" => "Credential Store after change",
      "rejected_reason" => include("captured \"/session/new\" titled \"Sign in\"", "Credential Store after change")
    ))

    run_visual_diff_step(result.workflow, job)

    result.workflow.reload
    expect(result.workflow.artifact("visual_diff_skipped_reason")).to include(
      "captured \"/session/new\" titled \"Sign in\"",
      "Credential Store after change"
    )
    expect(result.workflow.artifact("visual_diff_pairs")).to be_nil
    expect(Array(result.workflow.artifact("typed_artifacts")).pluck("type")).not_to include("visual_diff_comparison")
  end

  it "keeps auth-page visual diffs when the changed surface is the auth route" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "implemented",
      issue_title: "Polish sign-in",
      issue_body: "The changed surface is /session/new."
    )
    after_workflow_for(job, artifacts: [ sign_in_after_artifact ])

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(result.workflow.artifact("visual_diff_after_artifacts")).to contain_exactly(include("title" => "Credential Store after change"))
    expect(result.workflow.artifact("visual_diff_rejected_after_artifacts")).to be_empty
  end

  it "rejects a manual request without after screenshots" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")

    result = described_class.call(job: job)

    expect(result).not_to be_success
    expect(result.error).to include("No visual review screenshots")
    expect(job.workflows.where(trigger_kind: "visual_diff")).to be_empty
  end

  it "creates an idempotent deferred workflow for an approved visual review iteration" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    workflow = after_workflow_for(job, trigger_kind: "initial")

    expect {
      described_class.enqueue_deferred_for_visual_review(workflow)
      described_class.enqueue_deferred_for_visual_review(workflow)
    }.to change { job.workflows.where(trigger_kind: "visual_diff").count }.by(1)

    deferred = job.workflows.where(trigger_kind: "visual_diff").last
    expect(deferred).to have_attributes(priority: "low")
    expect(deferred.artifact("visual_diff_source")).to eq("visual_review")
  end

  it "does not create deferred work before the job is implemented" do
    job = Factories.job_record(user: user, repository: repository, state: "running")
    workflow = after_workflow_for(job, trigger_kind: "initial")

    expect {
      described_class.enqueue_deferred_for_visual_review(workflow)
    }.not_to change { job.workflows.where(trigger_kind: "visual_diff").count }
  end

  it "does not create deferred work after the job has already been approved" do
    job = Factories.job_record(user: user, repository: repository, state: "approved")
    workflow = after_workflow_for(job, trigger_kind: "initial")

    expect {
      described_class.enqueue_deferred_for_visual_review(workflow)
    }.not_to change { job.workflows.where(trigger_kind: "visual_diff").count }
  end

  it "creates deferred visual diff work when the job becomes implemented" do
    job = Factories.job_record(user: user, repository: repository, state: "running")
    after_workflow_for(job, trigger_kind: "initial")

    expect {
      job.update!(state: "implemented")
    }.to change { job.workflows.where(trigger_kind: "visual_diff").count }.by(1)

    deferred = job.workflows.where(trigger_kind: "visual_diff").last
    expect(deferred.artifact("visual_diff_source")).to eq("visual_review")
  end

  it "does not enqueue deferred work when the visual review produced no screenshots" do
    job = Factories.job_record(user: user, repository: repository, state: "running")
    workflow = after_workflow_for(job, artifacts: [])

    expect {
      described_class.enqueue_deferred_for_visual_review(workflow)
    }.not_to change { job.workflows.where(trigger_kind: "visual_diff").count }
  end

  it "cancels automatic deferred visual diff work after approval" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    workflow = after_workflow_for(job)
    described_class.enqueue_deferred_for_visual_review(workflow)
    deferred = job.workflows.where(trigger_kind: "visual_diff").last

    StateTransition.with_source("operator") do
      job.approve!(via: "operator", by_user: user)
    end

    expect(deferred.reload).to be_cancelled
    expect(deferred.artifact("cancelled_reason")).to eq("visual_diff_obsolete")
  end
end
