require "rails_helper"

RSpec.describe App::ChatMessagePayload do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(user: user, repository: repository) }

  it "returns materialized job details for a confirmed job proposal" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Add inspection tools", state: "open")
    proposal = chat.proposals.create!(
      repository: repository,
      job: job,
      kind: "job",
      state: "confirmed",
      slug: "inspection-tools",
      title: "Add inspection tools",
      body: "Inspect more."
    )
    message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal confirmed." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:materialized)).to eq(
      kind: "job",
      job_id: job.id,
      job_title: "Add inspection tools",
      job_state: "open"
    )
  end

  it "returns materialized epic details and child jobs for a confirmed epic bundle" do
    epic = Factories.epic(user: user, repository: repository, title: "Chat-driven job feedback loop")
    parent = chat.proposals.create!(
      repository: repository,
      epic: epic,
      kind: "epic",
      state: "confirmed",
      slug: "feedback-loop",
      title: "Chat-driven job feedback loop",
      body: "Bundle the work."
    )
    child_job = Factories.job_record(user: user, repository: repository, issue_title: "Add trigger", state: "queued")
    chat.proposals.create!(
      repository: repository,
      parent_proposal: parent,
      job: child_job,
      kind: "job",
      state: "confirmed",
      slug: "add-trigger",
      title: "Add trigger",
      body: "Trigger it."
    )
    message = chat.messages.create!(role: "assistant", proposal: parent, content: { "text" => "Epic proposal confirmed." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:materialized)).to eq(
      kind: "epic",
      epic_id: epic.id,
      epic_title: "Chat-driven job feedback loop",
      child_jobs: [
        { job_id: child_job.id, title: "Add trigger" }
      ]
    )
  end

  it "includes inline pending action details with a job resource" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Inject memories into chat system prompt", state: "implemented")
    action = chat.pending_actions.create!(
      action: "cancel_job",
      requested_by: "agent",
      payload: { "job_id" => job.id }
    )
    message = chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Cancel it?" })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:pending_action)

    expect(payload).to eq(
      id: action.id,
      action: "cancel_job",
      state: "pending",
      label: "Cancel JOB-#{job.id}",
      app_confirm_path: "/api/v1/app/chats/#{chat.id}/pending_actions/#{action.id}/confirm",
      app_reject_path: "/api/v1/app/chats/#{chat.id}/pending_actions/#{action.id}/reject",
      resource_title: "Inject memories into chat system prompt",
      resource_url: "/jobs/#{job.id}"
    )
  end

  it "omits pending action resource fields when the referenced job is gone" do
    action = chat.pending_actions.create!(
      action: "cancel_job",
      requested_by: "agent",
      payload: { "job_id" => 999_999 }
    )
    message = chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Cancel it?" })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:pending_action)

    expect(payload).to include(
      id: action.id,
      action: "cancel_job",
      label: "Cancel JOB-999999"
    )
    expect(payload).not_to have_key(:resource_title)
    expect(payload).not_to have_key(:resource_url)
  end
end
