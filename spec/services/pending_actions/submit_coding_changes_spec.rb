require "rails_helper"

RSpec.describe PendingActions::SubmitCodingChanges do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def enable_coding_mode!
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: true)
  end

  def pending_action(overrides = {})
    chat_session.pending_actions.create!({
      action: "submit_coding_changes",
      payload: {
        "repository_id" => repository.id,
        "branch" => "feature/my-work",
        "description" => "Add user profile page"
      },
      requested_by: "agent"
    }.merge(overrides))
  end

  before { enable_coding_mode! }

  it "creates a direct Job linked to the chat session" do
    action = pending_action

    allow(StepDispatcher).to receive(:start_workflow)
    expect { action.confirm!(user: user) }.to change(Job, :count).by(1)

    job = Job.order(:created_at).last
    expect(job).to have_attributes(
      kind: "direct",
      branch_name: "feature/my-work",
      issue_body: "Add user profile page",
      linked_chat_id: chat_session.id,
      repository: repository
    )
  end

  it "dispatches a coding_handoff workflow and stores it as the result" do
    action = pending_action

    allow(StepDispatcher).to receive(:start_workflow)
    action.confirm!(user: user)

    expect(action.reload).to be_confirmed
    expect(action.result).to be_a(Workflow)
    expect(action.result.trigger_kind).to eq("coding_handoff")
  end

  it "transitions the new Job to implemented state (out of coding) after handoff" do
    action = pending_action

    allow(StepDispatcher).to receive(:start_workflow)
    action.confirm!(user: user)

    job = action.result.job
    expect(job.reload).to be_implemented
  end

  it "sets the Job's branch_name from the payload" do
    action = pending_action

    allow(StepDispatcher).to receive(:start_workflow)
    action.confirm!(user: user)

    expect(action.result.job.branch_name).to eq("feature/my-work")
  end

  it "enqueues GenerateJobTitleJob for the created Job when title is absent" do
    action = pending_action

    allow(StepDispatcher).to receive(:start_workflow)
    expect {
      action.confirm!(user: user)
    }.to have_enqueued_job(GenerateJobTitleJob)
  end

  context "when title is provided in the payload" do
    def pending_action_with_title
      chat_session.pending_actions.create!(
        action: "submit_coding_changes",
        payload: {
          "repository_id" => repository.id,
          "branch" => "feature/my-work",
          "description" => "Add user profile page",
          "title" => "User Profile Page"
        },
        requested_by: "agent"
      )
    end

    it "sets issue_title from the payload and skips GenerateJobTitleJob" do
      action = pending_action_with_title

      allow(StepDispatcher).to receive(:start_workflow)
      expect {
        action.confirm!(user: user)
      }.not_to have_enqueued_job(GenerateJobTitleJob)

      job = action.result.job
      expect(job.issue_title).to eq("User Profile Page")
      expect(job.title_pending).to be(false)
    end
  end

  it "raises RecordNotFound when the repository belongs to another user" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    action = pending_action({ payload: { "repository_id" => other_repo.id, "branch" => "main", "description" => "stuff" } })

    expect { action.confirm!(user: user) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "raises ArgumentError when coding mode is disabled during confirmation" do
    action = pending_action
    Feature.find_by(slug: "coding_mode")&.update!(enabled: false)

    expect { action.confirm!(user: user) }.to raise_error(ArgumentError, /could not start coding handoff/)
  end

  it "validates that repository_id is present in the payload" do
    action = chat_session.pending_actions.build(
      action: "submit_coding_changes",
      payload: { "branch" => "main", "description" => "stuff" },
      requested_by: "agent"
    )

    expect(action).not_to be_valid
    expect(action.errors.to_a).to include(match(/repository_id/))
  end

  it "validates that branch is present in the payload" do
    action = chat_session.pending_actions.build(
      action: "submit_coding_changes",
      payload: { "repository_id" => repository.id, "description" => "stuff" },
      requested_by: "agent"
    )

    expect(action).not_to be_valid
    expect(action.errors.to_a).to include(match(/branch/))
  end

  it "validates that description is present in the payload" do
    action = chat_session.pending_actions.build(
      action: "submit_coding_changes",
      payload: { "repository_id" => repository.id, "branch" => "main" },
      requested_by: "agent"
    )

    expect(action).not_to be_valid
    expect(action.errors.to_a).to include(match(/description/))
  end
end
