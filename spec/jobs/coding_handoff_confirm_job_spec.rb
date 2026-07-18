require "rails_helper"

RSpec.describe CodingHandoffConfirmJob do
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
        "title" => "User Profile Page",
        "description" => "Add user profile page"
      },
      requested_by: "agent",
      state: "confirmed"
    }.merge(overrides))
  end

  let(:snapshot) do
    {
      "source_branch" => "feature/my-work",
      "handoff_branch" => nil,
      "head_sha" => "abc123",
      "base_sha" => "def456",
      "default_branch" => repository.default_branch,
      "changed_files" => [ "app/frontend/App.tsx" ],
      "captured_at" => Time.current.iso8601,
      "chat_session_id" => chat_session.id
    }
  end

  before do
    enable_coding_mode!
    allow(CodingHandoffCapture).to receive(:capture!) do |chat_session:, repository:, user:, source_branch:, handoff_branch:|
      snapshot.merge("handoff_branch" => handoff_branch)
    end
    allow(StepDispatcher).to receive(:start_workflow)
  end

  it "runs on the chat queue" do
    expect(described_class.new.queue_name).to eq("chat")
  end

  it "is discarded when the pending action does not exist" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end

  it "creates a direct Job linked to the chat session" do
    action = pending_action

    expect { described_class.perform_now(action.id) }.to change(Job, :count).by(1)

    job = Job.order(:created_at).last
    expect(job).to have_attributes(
      kind: "direct",
      issue_title: "User Profile Page",
      issue_body: "Add user profile page",
      linked_chat_id: chat_session.id,
      repository: repository
    )
  end

  it "derives the immutable handoff branch name from the chat session and pending action ids" do
    action = pending_action

    described_class.perform_now(action.id)

    job = Job.order(:created_at).last
    expect(job.branch_name).to eq("syrus/chat-#{chat_session.id}-handoff-#{action.id}")
    expect(CodingHandoffCapture).to have_received(:capture!).with(
      chat_session: chat_session,
      repository: repository,
      user: user,
      source_branch: "feature/my-work",
      handoff_branch: "syrus/chat-#{chat_session.id}-handoff-#{action.id}"
    )
  end

  it "dispatches a coding_handoff workflow" do
    action = pending_action

    described_class.perform_now(action.id)

    job = Job.order(:created_at).last
    workflow = job.workflows.order(:created_at).last
    expect(workflow).to have_attributes(trigger_kind: "coding_handoff")
  end

  it "seeds PR title, body, and empty test-plan artifacts on the workflow" do
    action = pending_action

    described_class.perform_now(action.id)

    workflow = Job.order(:created_at).last.workflows.order(:created_at).last
    expect(workflow.artifact("pr_title")).to eq("User Profile Page")
    expect(workflow.artifact("pr_body")).to include("Captured chat workspace commit `abc123`")
    expect(workflow.artifact("pr_body")).to include("- `app/frontend/App.tsx`")
    expect(workflow.artifact("test_plan")).to eq("steps" => [], "notes" => nil)
  end

  it "seeds coding_handoff snapshot into workflow artifacts" do
    action = pending_action

    described_class.perform_now(action.id)

    workflow = Job.order(:created_at).last.workflows.order(:created_at).last
    expect(workflow.artifact("coding_handoff")).to include(
      "source_branch" => "feature/my-work",
      "handoff_branch" => "syrus/chat-#{chat_session.id}-handoff-#{action.id}",
      "head_sha" => "abc123"
    )
  end

  it "posts a success system message and enqueues ChatTurnJob" do
    action = pending_action

    expect {
      described_class.perform_now(action.id)
    }.to have_enqueued_job(ChatTurnJob)

    message = chat_session.messages.where(role: "system").order(:created_at).last
    expect(message).to be_present
    expect(message.content["source"]).to eq(CodingHandoffConfirmJob::SOURCE)
    expect(message.content["text"]).to include("dispatched")
  end

  it "posts a failure system message and enqueues ChatTurnJob on CaptureError" do
    action = pending_action
    allow(CodingHandoffCapture).to receive(:capture!).and_raise(
      CodingHandoffCapture::CaptureError, "coding checkout not found for #{repository.slug}"
    )

    expect {
      described_class.perform_now(action.id)
    }.to have_enqueued_job(ChatTurnJob)

    message = chat_session.messages.where(role: "system").order(:created_at).last
    expect(message.content["source"]).to eq(CodingHandoffConfirmJob::SOURCE)
    expect(message.content["text"]).to include("failed")
    expect(message.content["text"]).to include("coding checkout not found")
  end

  it "posts a failure message and enqueues ChatTurnJob when start_coding_handoff! is blocked" do
    action = pending_action
    Feature.find_by(slug: "coding_mode")&.update!(enabled: false)

    expect {
      described_class.perform_now(action.id)
    }.to have_enqueued_job(ChatTurnJob)

    message = chat_session.messages.where(role: "system").order(:created_at).last
    expect(message.content["source"]).to eq(CodingHandoffConfirmJob::SOURCE)
    expect(message.content["text"]).to include("failed")
    expect(message.content["text"]).to include("could not start coding handoff")
  end

  it "does not raise when the pending action has been discarded" do
    expect { described_class.perform_now(0) }.not_to raise_error
    expect(Job.count).to eq(0)
  end
end
