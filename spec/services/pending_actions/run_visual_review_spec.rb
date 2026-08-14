require "rails_helper"

RSpec.describe PendingActions::RunVisualReview do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def stub_visual_review_plan(enabled:)
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
      RepoVisualReviewPlan::Result.new(enabled: enabled, rounds: 1, source: ".syrus.yml", note: nil)
    )
  end

  def pending_action(job)
    chat_session.pending_actions.create!(
      action: "run_visual_review",
      payload: { "job_id" => job.id },
      requested_by: "agent"
    )
  end

  it "dispatches a manual_visual_review workflow and stores it as the result" do
    stub_visual_review_plan(enabled: true)
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    action = pending_action(job)

    action.confirm!(user: user)

    expect(action.reload).to be_confirmed
    expect(action.result).to be_a(Workflow)
    expect(action.result.trigger_kind).to eq("manual_visual_review")
  end

  it "raises ArgumentError when the job is not runnable" do
    stub_visual_review_plan(enabled: true)
    job = Factories.job_record(user: user, repository: repository, state: "running")
    action = pending_action(job)

    expect { action.confirm!(user: user) }.to raise_error(ArgumentError, /implemented or approved/)
  end

  it "raises ArgumentError when visual review is not configured" do
    stub_visual_review_plan(enabled: false)
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    action = pending_action(job)

    expect { action.confirm!(user: user) }.to raise_error(ArgumentError, /not configured/)
  end

  it "raises RecordNotFound when the job belongs to another user" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    other_job = Factories.job_record(user: other_user, repository: other_repo, state: "implemented")
    action = chat_session.pending_actions.create!(
      action: "run_visual_review",
      payload: { "job_id" => other_job.id },
      requested_by: "agent"
    )

    expect { action.confirm!(user: user) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
