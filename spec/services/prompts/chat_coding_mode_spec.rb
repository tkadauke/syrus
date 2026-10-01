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

  it "directs linked coding Jobs to complete_implement_step only" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "coding",
      issue_title: "Repair aqueduct flow",
      branch_name: "syrus/job-42"
    )
    job.update_columns(linked_chat_id: chat_session.id)

    expect(prompt).to include("Existing Job is actually in `coding` and linked to this chat")
    expect(prompt).to include("commit, verify the working tree is clean")
    expect(prompt).to include("Verify the working tree is clean")
    expect(prompt).to include("captures and publishes the active checkout branch")
    expect(prompt).to include("Attached Jobs are context, not proof")
    expect(prompt).to include("Handoff lane: `complete_implement_step(job_id: #{job.id})`")
    expect(prompt).not_to include("git push origin HEAD:<job-branch>")
    expect(prompt).not_to include("after pushing the Job branch")
  end

  it "tells agents to open implemented or approved Jobs before editing" do
    implemented = Factories.job_record(
      user: user,
      repository: repository,
      state: "implemented",
      issue_title: "Repair aqueduct flow",
      branch_name: "syrus/job-42"
    )
    chat_session.chat_attachments.create!(attachable: implemented)

    expect(prompt).to include("Existing Job is `implemented` or `approved`: call")
    expect(prompt).to include("`open_in_coding_mode(job_id: <id>)` before editing")
    expect(prompt).to include("Handoff lane: call `open_in_coding_mode(job_id: #{implemented.id})` before editing")
  end

  it "includes the recovery recipe for edits made before takeover" do
    expect(prompt).to include("Edits were already made before opening/taking over the existing")
    expect(prompt).to include("preserve them first with a local backup branch or tag")
    expect(prompt).to include("`cancel_coding_checkout`")
    expect(prompt).to include("cherry-pick or")
    expect(prompt).to include("then use `complete_implement_step`")
  end

  it "directs new chat-authored work with no attached Job to submit_coding_changes" do
    expect(prompt).to include("New chat-authored work only")
    expect(prompt).to include("`submit_coding_changes` from the active branch")
    expect(prompt).to include("captures HEAD to an immutable")
    expect(prompt).to match(/do not create or\s+push a persistent branch/)
  end
end
