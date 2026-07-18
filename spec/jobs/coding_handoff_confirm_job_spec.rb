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
      requested_by: "agent"
    }.merge(overrides))
  end

  def fake_snapshot(action, branch: "feature/my-work")
    handoff_branch = "syrus/chat-#{chat_session.id}-handoff-#{action.id}"
    {
      "source_branch" => branch,
      "handoff_branch" => handoff_branch,
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
    allow(CodingHandoffCapture).to receive(:capture!) { |**kw| fake_snapshot(kw[:chat_session].pending_actions.last) }
    allow(StepDispatcher).to receive(:start_workflow)
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
    expect(job.branch_name).to match(%r{\Asyrus/chat-#{chat_session.id}-handoff-\d+\z})
  end

  it "dispatches a coding_handoff workflow" do
    action = pending_action

    described_class.perform_now(action.id)

    workflow = Job.order(:created_at).last.workflows.last
    expect(workflow).to be_a(Workflow)
    expect(workflow.trigger_kind).to eq("coding_handoff")
  end

  it "transitions the new Job to implemented state (out of coding) after handoff" do
    action = pending_action

    described_class.perform_now(action.id)

    job = Job.order(:created_at).last
    expect(job.reload).to be_implemented
  end

  it "uses an immutable handoff branch derived from the pending action id" do
    action = pending_action

    described_class.perform_now(action.id)

    expect(CodingHandoffCapture).to have_received(:capture!).with(
      chat_session: chat_session,
      repository: repository,
      user: user,
      source_branch: "feature/my-work",
      handoff_branch: "syrus/chat-#{chat_session.id}-handoff-#{action.id}"
    )
    expect(Job.order(:created_at).last.branch_name).to eq("syrus/chat-#{chat_session.id}-handoff-#{action.id}")
  end

  it "seeds PR summary artifacts from the handoff snapshot" do
    action = pending_action

    described_class.perform_now(action.id)

    workflow = Job.order(:created_at).last.workflows.last.reload
    expect(workflow.artifact("pr_title")).to eq("User Profile Page")
    expect(workflow.artifact("pr_body")).to include("Captured chat workspace commit `abc123`")
    expect(workflow.artifact("pr_body")).to include("- `app/frontend/App.tsx`")
    expect(workflow.artifact("test_plan")).to eq("steps" => [], "notes" => nil)
  end

  it "does not enqueue GenerateJobTitleJob when title is provided" do
    action = pending_action

    expect { described_class.perform_now(action.id) }.not_to have_enqueued_job(GenerateJobTitleJob)
  end

  it "posts a success system message to the chat" do
    action = pending_action

    described_class.perform_now(action.id)

    messages = chat_session.messages.where(role: "system").reload
    success_message = messages.find { |m| m.content["text"].to_s.include?("Coding handoff submitted") }
    expect(success_message).to be_present
    expect(success_message.content["text"]).to include("JOB-")
  end

  it "enqueues ChatTurnJob with the success message" do
    action = pending_action

    expect { described_class.perform_now(action.id) }.to have_enqueued_job(ChatTurnJob)
  end

  context "when CodingHandoffCapture raises CaptureError" do
    before do
      allow(CodingHandoffCapture).to receive(:capture!)
        .and_raise(CodingHandoffCapture::CaptureError, "coding checkout not found")
    end

    it "posts a failure message to the chat instead of raising" do
      action = pending_action

      expect { described_class.perform_now(action.id) }.not_to raise_error

      messages = chat_session.messages.where(role: "system").reload
      failure_message = messages.find { |m| m.content["text"].to_s.include?("Coding handoff failed") }
      expect(failure_message).to be_present
      expect(failure_message.content["text"]).to include("coding checkout not found")
    end

    it "does not create a Job" do
      action = pending_action

      expect { described_class.perform_now(action.id) }.not_to change(Job, :count)
    end

    it "enqueues ChatTurnJob to deliver the failure message" do
      action = pending_action

      expect { described_class.perform_now(action.id) }.to have_enqueued_job(ChatTurnJob)
    end
  end

  context "when coding mode is disabled" do
    before do
      Feature.find_by(slug: "coding_mode")&.update!(enabled: false)
    end

    it "posts a failure message to the chat" do
      action = pending_action

      expect { described_class.perform_now(action.id) }.not_to raise_error

      messages = chat_session.messages.where(role: "system").reload
      failure_message = messages.find { |m| m.content["text"].to_s.include?("Coding handoff failed") }
      expect(failure_message).to be_present
    end
  end

  context "when the pending action does not exist" do
    it "is silently discarded (no exception)" do
      expect { described_class.perform_now(999_999) }.not_to raise_error
    end
  end
end
