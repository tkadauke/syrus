require "rails_helper"

RSpec.describe Prompts::ChatCodingMode do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) do
    ChatSession.create!(
      user: user,
      repository: repository,
      mode: "coding",
      coding_checkout_branch: "syrus/job-42",
      coding_checkout_prepare_status: "complete"
    )
  end

  before do
    allow(ChatWorkspace).to receive(:coding_checkout_snapshot).and_return(
      path: "/tmp/coding/acme/widgets",
      exists: true,
      current_branch: "syrus/job-42",
      configured_branch: "syrus/job-42",
      head_sha: "abc123",
      default_branch: "main",
      prepare_status: "complete",
      prepare_started_at: nil,
      prepare_finished_at: nil,
      prepare_failure: nil
    )
  end

  subject(:prompt) { described_class.new(chat_session: chat_session).to_s }

  it "directs attached existing Jobs to complete_implement_step only" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "coding",
      issue_title: "Repair aqueduct flow",
      branch_name: "syrus/job-42"
    )
    job.update_columns(linked_chat_id: chat_session.id)

    expect(prompt).to include("Attached existing Job: call `complete_implement_step")
    expect(prompt).to include("Do not use `submit_coding_changes` for a Job already")
    expect(prompt).to include("Job ID: #{job.id} (pass to `complete_implement_step`)")
  end

  it "directs new chat-authored work with no attached Job to submit_coding_changes" do
    expect(prompt).to include("New chat-authored work with no attached Job: call")
    expect(prompt).to include("`submit_coding_changes` from the active branch")
    expect(prompt).to include("captures HEAD to an immutable")
  end
end
